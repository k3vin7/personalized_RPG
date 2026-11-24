class_name SkillDef
extends Resource

# One slot's worth of action, as data. M-1: the eight slots are filled with
# these, and the cast flow (windup -> ruling -> recovery) reads every number
# off one. Nothing about a skill is a literal in code: a field here, or a
# Tuning.server slider this file points at.
#
# The two actions that already existed, the shove and the grab, are wrapped by
# one of these too. Their rulings stay where they were (Intent.SHOVE, GRAB);
# the slot only calls the same entry the key used to.

enum Hands {
	BARE,
	ONE_HAND_WEAPON,
	OFF_HAND,
	TWO_HANDS,
}

enum Outcome {
	NONE,
	KNOCKBACK,
	DOWN,
	# C-1c: the ruling throws the off-hand weapon as a body (the shield)
	# instead of striking.
	THROW_WEAPON,
}

# M-6: how the key is read. PRESS_CAST is the cast flow (arm or cast on the
# press, windup, ruling, recovery). HOLD_RELEASE is the grab's: the press is
# the request (or, with something in hand, the start of a charge), the release
# decides -- under the threshold a put-down, over it an arc, C a line. The
# smart key and the left button play no part in it.
enum InputMode {
	PRESS_CAST,
	HOLD_RELEASE,
	# C-1c: held up while the key is down (the shield raise). The press
	# opens it, the release ends it; no windup, no ruling of its own.
	HOLD_BLOCK,
}

# C-0: the shape drawn on the ground when the key arms this skill (smart key
# off), and the shape a scarecrow's telegraph fills in during its windup. The
# ruling does not read this; it is a picture of the numbers above. NONE is
# "no range to show" -- the parry, the shield raise, and anything held.
enum RangeShape {
	NONE,
	# A bar out of the body: reach long, width across, with a pointed end.
	# The thrust and the shield throw.
	LINE,
	# A plain rectangle: reach deep, width across. The shove, the shield bash,
	# the overhead cut (narrow), the punch and the kick.
	RECT,
	# A horizontal sector of radius reach, shape_angle_deg wide. The side cut.
	FAN,
	# A disc of circle_radius, centred reach ahead. The shield slam.
	CIRCLE,
}

# C-1a: what kind of damage this is. Every C-1 skill is physical and not
# holy; the fields are here for the tags the design names.
enum AttackTag {
	PHYSICAL,
	MAGIC,
}

# C-0: which way the strike bar sweeps. Horizontal is a yaw sweep (a side
# cut); vertical is a pitch sweep (an overhead cut, a kick). A sweep of zero
# is a thrust along the heading either way.
enum ArcPlane {
	HORIZONTAL,
	VERTICAL,
}

@export var id: String = ""
@export var label: String = ""
@export var hands: Hands = Hands.BARE
# Which door the cast goes through on the server, as ServerAuthority.Intent.
# -1 means Intent.SKILL, the generic strike door; the shove and the grab name
# their own.
@export var intent: int = -1
@export var input_mode: InputMode = InputMode.PRESS_CAST
# Seconds. Windup is the time from the cast to the ruling; recovery the time
# after it. Both lock out moving, jumping, dashing and other casts.
@export var windup: float = 0.0
@export var recovery: float = 0.0
@export var cooldown: float = 0.0
# The hit rectangle: this far ahead, this wide.
@export var reach: float = 1.5
@export var width: float = 1.2
# C-1a: the '피해' column is a coefficient on the weapon's attack power
# (WeaponDef, by weapon_id). Bare hands are 1, so for the bare four this is
# the damage itself.
@export var damage: float = 0.0
@export var weapon_id: String = "bare"
# Set only on the copy Skills.for_holder makes for a family member of
# weapon_id (the great sword): value() multiplies by that weapon's numbers.
# Null on the file's own def.
var wielded: WeaponDef = null
@export var knock_power: float = 0.0
# 2026-11-23 (the user): whether the blow pushes a body (a person, a scarecrow,
# a monster) at all. Off, it pushes nothing and the body flinches instead
# (Dummy.flinch); knock_power stays in the data for the day it is turned on.
# A rock is pushed either way. The monsters' own blows have it on.
@export var knocks_back: bool = false
# 2026-11-24 (the user): the dash may cut this skill's recovery short from
# this many seconds after its blade has passed (0: at once); -1 never. The
# slider <tuning_prefix>_dash_cancel_after overrides it where there is one.
@export var dash_cancel_after: float = 0.0
# C-1a: the '스태미나' column. A fixed cost per cast; 0 stamina refuses the
# cast at the intent (C-1b/C-1d spend it, this stage carries it).
@export var stamina_cost: float = 0.0
# C-1a: damage itself never stuns (only a launch does); a skill that says so
# here stuns for this long on a hit. 0 for everything in C-1 but the parry.
@export var stun_on_hit: float = 0.0
@export var attack_tag: AttackTag = AttackTag.PHYSICAL
@export var holy: bool = false
# C-1b: a body off the ground (a jump, a launch) is not hit by this skill.
# The side cut's rule; everything else reaches a body in the air that is
# inside its height band.
@export var skip_airborne: bool = false
# 2026-11-23 (the user): a blow made at the ground that does not reach a body
# standing on a monster's back (the wolf's bite; whose back is the server's
# rider table). A monster's own blow never reaches its own rider, flag or not.
@export var passes_riders: bool = false
# C-1b: damage x (1 + this x the caster's horizontal speed at the intent,
# as the server saw it, / base_move_speed). The thrust's; 0 for the rest.
@export var speed_bonus: float = 0.0
# C-1c: damage x (1 + this x metres fallen by the caster when it lands, off
# the server's record of its peak). The shield slam's; 0 for the rest.
@export var height_bonus: float = 0.0
# C-1c: may be cast from the air (the shield slam). The owner sends the
# intent without leaving AIRBORNE; the ruling lands at the impact time.
@export var usable_airborne: bool = false
# C-1c: a team mate in the air is launched rather than pushed (the shove's
# co-op step), with the shove's angle. The shield bash's.
@export var launches_airborne_ally: bool = false
# C-1d: pressed within dash_combo_window of a dash's start, this skill is
# the dash combo: cast from the dash itself (the body keeps dashing; the
# ruling lands at the impact time) and stronger the earlier the press. The
# punch's, the thrust's and the shield bash's.
@export var dash_combo: bool = false
# M-7: when the ruling lands, measured from the cast. 0 means "at the end of
# the windup", which is every strike today; a bow or a boss swing can put it
# elsewhere. The catch window closes at this moment.
@export var impact_at: float = 0.0
# M-7: how long before the impact a grab counts as catching this attack. 0
# means Tuning.server.catch_window.
@export var catch_window: float = 0.0
# M-7: the "force" of this attack for the catch: the catcher's strength has to
# be at least this times catch_power_mult. 0 means knock_power.
@export var catch_force: float = 0.0
@export var outcome: Outcome = Outcome.NONE
# Which base skill this is a variant of (empty: a base skill). Reserved.
@export var variant_of: String = ""
# M-2: the kick is the one attack that can be cast with the hands full.
@export var usable_while_holding: bool = false
# Where the numbers come from. Non-empty: Tuning.server.<prefix>_<field> for
# every field the table has (shove_range, punch_damage ...), so the slider is
# the value and this file only names the skill. Fields the table lacks fall
# back to the ones above.
@export var tuning_prefix: String = ""
# 2026-11-18: a second table to read where the first has no such field: a
# combo step names its own windup and recovery and takes the rest from the
# skill it is a step of.
@export var tuning_fallback_prefix: String = ""
# 2026-11-18: a combo. combo_next is the skill a press of this slot casts
# when the press comes while this one is still going (or within
# Tuning.server.combo_window of its end): it follows the moment this one's
# swing is through, with no recovery between. combo_of
# is the slot's skill, on a step (empty on the slot's own). The owner picks
# the step from its own presses; the server keeps its own record of the
# chain and refuses a step out of turn.
@export var combo_next: String = ""
@export var combo_of: String = ""
# The next step opens only if this one's blow landed on a body (the thrust:
# there is nothing to kick off and no blade to pull out of a miss). The
# server opens the chain at the hit and tells the owner; a parried blow and a
# rock do not count.
@export var combo_needs_hit: bool = false
# 2026-11-21: the next step follows only once this one's recovery is over,
# not at the end of its swing: this clip carries on into the next one. (Made
# for a rising cut of three blows, 2026-11-21; it has two now and nothing
# sets this.) The press is still asked for in the same window.
@export var combo_after_recovery: bool = false
# 2026-11-22: the next step starts this long after this one's blade is
# through (seconds of its clip; 0 = at once): the rising cut's blade passes
# on the ground and its dive starts from the top of the leap. The press is
# taken until then too (combo_press_until).
@export var combo_next_at: float = 0.0
# 2026-11-23 (the user: out of a thrust that is in, the other cuts): the
# slot skills that may follow this one out of turn -- a press of another
# slot holding one of these, while this cast's chain is open (so, with
# combo_needs_hit, only after it landed), casts that slot's skill the moment
# this blade is through, with no recovery between; that skill's own chain
# goes on from there. The server keeps the list with the chain it opened.
@export var combo_branches: PackedStringArray = PackedStringArray()
# 2026-11-23 (the user): standing on a monster's back, this slot casts
# on_back_skill instead (the thrust: the stab down). On that skill:
# needs_mount -- the server rules it only for a body its rider table has on
# a back, and it lands on that monster and nothing else; sure_crit -- its
# blow is always a crit.
@export var on_back_skill: String = ""
@export var needs_mount: bool = false
@export var sure_crit: bool = false
# 2026-11-23: >= 0: the next step follows by itself, this long after the
# blade is through (seconds; the slider <tuning_prefix>_combo_auto_after
# where there is one), if nothing was pressed -- and at once on a press of
# its own slot. The presses (its own, a branch's) are taken until then. -1:
# only on a press.
@export var combo_auto_after: float = -1.0
# 2026-11-20: the forms a skill takes as its mastery grows. form_skills[i] is
# the skill the slot casts once the caster's mastery of this skill
# (Mastery.level_of) is at least form_levels[i]; the highest such wins, and
# under all of them the skill is itself. On the form's own file: form_of is
# the skill it is a form of and form_level the mastery it asks for, which the
# server checks against its own number before it rules the cast.
@export var form_levels: PackedInt32Array = PackedInt32Array()
@export var form_skills: PackedStringArray = PackedStringArray()
@export var form_of: String = ""
@export var form_level: int = 0
@export_group("Display")
# The procedural show: how far the capsule leans into the windup and back out
# of the recovery, and the bar that is the strike -- how far it reaches and
# how high it sits. No rigs, no clips.
@export var windup_lean_deg: float = 14.0
@export var recovery_lean_deg: float = -6.0
@export var strike_extent: float = 0.8
@export var strike_height: float = 0.3
@export var colour: Color = Color("ffd166")
# 2026-11-19 (the dash cut): through the swing the body is not drawn, and a
# straight streak is, from where the swing began to where the body has got
# to. A picture only: the body is where it always was, and is hit there.
@export var vanish_streak: bool = false

@export_group("Range display")
# C-0. What the key shows before the left button casts. reach and width above
# size a LINE or a RECT; the FAN takes shape_angle_deg; the CIRCLE takes
# circle_radius.
@export var range_shape: RangeShape = RangeShape.RECT
@export var shape_angle_deg: float = 120.0
@export var circle_radius: float = 1.0
# A scarecrow (and, in C-2, a monster) casting this draws the same shape in
# red on the ground and fills it over the windup, so the impact can be read
# off the ground. A player's own casts show nothing to others.
@export var telegraph: bool = false

@export_group("Swing")
# C-0: the strike bar's arc. The pivot sits at strike_height on the body and
# the bar (the held weapon, or a limb for a bare skill) hangs strike_extent off
# it; over arc_duration seconds the pivot turns from arc_start() through
# arc_deg degrees in arc_plane, leaving a trail. Horizontal: positive is to
# the body's left. Vertical: positive is up. An arc of zero is a thrust, which
# pushes the bar out along the heading instead of turning it. arc_duration 0
# means PlayerSkills.STRIKE_SHOW.
#
# C-1g-a: arc_deg is THE angle of the swing. The ruling (judge_by_sweep), the
# swing the body draws, the trail and (C-1g-c) the range shape all read it,
# through value(): a sword skill's comes off Tuning.server.<prefix>_arc_deg
# (side_cut_arc_deg 240, overhead_cut_arc_deg 120), so one slider moves all
# of them. The direction is arc_reversed (the sign the old arc_sweep_deg
# carried); arc_centred puts the arc symmetrically about the heading (the
# side cut), otherwise it begins at arc_start_deg (the overhead cut's 90,
# straight up).
@export var arc_plane: ArcPlane = ArcPlane.HORIZONTAL
@export var arc_start_deg: float = 0.0
@export var arc_deg: float = 0.0
# True: the pivot turns the negative way (to the body's right, or downward).
@export var arc_reversed: bool = false
# True: the arc runs from +arc/2 to -arc/2 about the heading (or the other
# way when reversed); arc_start_deg is ignored.
@export var arc_centred: bool = false
# C-1g-a: ruled as a sweep. Instead of one fan at the impact, the server
# follows the blade through the swing (same arc, same easing, same clock as
# the picture) and a body is hit the tick the blade reaches its bearing; one
# hit per body per swing. The side cut (horizontal) and the overhead cut
# (vertical). Off: the instant rectangle/fan/circle of M-1..C-1c.
@export var judge_by_sweep: bool = false
@export var arc_duration: float = 0.0
@export var trail: bool = true
# The held weapon is drawn this many times its length for the swing (the
# trail follows), and its own length again after. 1 is the weapon as it
# is. The overhead cut's 1.3 (2026-11-03).
@export var weapon_length_mult: float = 1.0
# 2026-11-04: a cast drops the walk on the press (no sliding into the
# swing) and instead takes this many metres toward the aim, spread over
# the windup and the swing. 0 stands still. The body's own move, under
# the move check like any other; the ruling reads the body where it is.
@export var step_distance: float = 0.0
# 2026-11-18: when in the cast (0..1 of windup + swing) the step is taken:
# the body stands until step_from and has covered step_distance by step_to.
# 0 and 1 spread it evenly over the whole cast, as before. Set to where the
# clip's own feet move, so they do not slide under a body moving on its own.
@export var step_from: float = 0.0
@export var step_to: float = 1.0
# 2026-11-19: metres more the body goes forward through the recovery, after
# the swing (the overhead cut: its blow ends with the other foot forward, and
# the way back into the stance is one more step on). The body's own move like
# step_distance, under the same move check. 0: it stands through its recovery.
@export var recovery_step: float = 0.0

@export_group("Motion")
# 2026-11-21 (the user: "make it off the clip's own motion"): the cast's
# timing and the body's path, measured off the clip the skill plays on the
# reference model (the mannequin) and written here by
# tools/sword_animset/bake.tscn -- not read off an animation at run time, so
# the server (which plays none) rules off the same numbers the owner moves by.
# With motion_times filled, the windup, the swing and the recovery are these
# over motion_speed (step_distance/from/to and the windup/recovery sliders are
# not used), and the body follows motion_path through the whole cast,
# recovery included: (right, up, forward) metres from where the cast began,
# against the aim; motion_yaw is its turn, degrees, + to the left. The
# horizontal is scaled by motion_reach, the height is the clip's.
# motion_speed and motion_reach are sliders (<prefix>_motion_speed/_reach).
# 2026-11-21 (the user): motion_recovery_speed runs the way back (and the
# body's path through it) that many times faster on top of motion_speed (the
# side cut's last step: 1.5 s of clip). Both sliders as well.
# The return (2026-11-21, the user): a clip that does not end in the stance
# (the rising cut's first blow, a piece cut out of a combo clip; the thrust,
# which ends in a pause) steps back into it after its clip, over
# motion_return seconds (its own slider, <tuning_prefix>_motion_return, no
# fallback): motion_return_foot stays where it is and the body -- the
# capsule, the hit box -- goes motion_return_move (right, 0, forward metres
# off the aim) so that the foot ends where the stance has it, while the other
# foot steps through. Baked with the rest: where the stance's feet are
# against the clip's last frame.
@export var motion_clip: String = ""
@export var motion_windup: float = 0.0
@export var motion_swing: float = 0.0
@export var motion_recovery: float = 0.0
@export var motion_times: PackedFloat32Array = PackedFloat32Array()
@export var motion_path: PackedVector3Array = PackedVector3Array()
@export var motion_yaw: PackedFloat32Array = PackedFloat32Array()
@export var motion_speed: float = 1.0
@export var motion_reach: float = 1.0
@export var motion_recovery_speed: float = 1.0
# 2026-11-24 (the user): the path's height is not the clip's but the body's
# own (Player.skill_lift_height: strength over weight, on Tuning.ratio_curve)
# -- the path's up and down are scaled so its top (motion_lift) is that
# height. The rising cut's leap, and its dive back down the same height.
@export var lift_by_ratio: bool = false
@export var motion_return: float = 0.0
@export var motion_return_foot: String = ""
@export var motion_return_move: Vector3 = Vector3.ZERO
# 2026-11-23 (the user: the pull is the thrust's own way back): a step with
# no clip of its own -- its whole picture and path are the return above, out
# of the pose the step before it left (the path is two samples of standing
# still, so the server times and checks it like any baked cast).
@export var motion_return_only: bool = false

@export_group("Guard")
# 2026-11-22: a held guard (input_mode HOLD_BLOCK: the shield raise, the
# sword's block), ruled by ServerAuthority's block. Its angle is
# shape_angle_deg. The share of a guarded blow's damage that still lands
# (the shield 0, the sword 0.15); the rest comes off the stamina.
@export var guard_damage_taken: float = 0.0
# Seconds after the press before it guards (-1: shield_raise_time).
@export var guard_raise_time: float = -1.0
# Whether holding it builds the posture that raises the push tolerance (the
# shield's); without, a guarded blow pushes like a hit.
@export var guard_posture_builds: bool = true
# The perfect guard: a blow inside this long after the press, with the
# guard's mastery at guard_perfect_mastery or more, costs nothing, does not
# push (super stance) and holds the attacker still (guard_perfect_stun).
# 0: none. guard_reflect_mastery: from that mastery a thrown thing inside the
# same window is sent back (-1: never).
@export var guard_perfect_window: float = 0.0
@export var guard_perfect_mastery: int = 1
@export var guard_reflect_mastery: int = -1
# 2026-11-23: a thrown thing is sent back only inside this long after the
# press (0: the perfect window).
@export var guard_reflect_window: float = 0.0
# 2026-11-22 (the user): the shield follows the cursor while it is up and may
# be walked with (at guard_move_mult of the walk); the sword turns to the
# cursor once, at the press, and holds the body still (0).
@export var guard_follows_cursor: bool = true
# 2026-11-23 (the user): the least the guard stays up after the press,
# seconds (0: it comes down with the key, the shield's). Until then the key
# coming up is remembered and no other skill is cast out of it; a perfect
# guard ends the hold at once. Kept by the server on its own clock.
@export var guard_min_hold: float = 0.0
@export var guard_move_mult: float = 1.0
# 2026-11-22 (the user): from guard_counter_mastery, a melee blow perfectly
# guarded opens the counter: for guard_counter_window (PhysicsTuning) the
# slot of guard_counter_skill's combo_of casts guard_counter_skill instead
# (the combo chain, server and owner alike). "" / -1: none.
@export var guard_counter_skill: String = ""
@export var guard_counter_mastery: int = -1

@export_group("Feedback")
# C-0: a hit by this skill shakes the camera as well as the rest of the hit
# feedback set. Big swings only; the tolerance verdict (launched) also shakes.
@export var feedback_big: bool = false

# SkillDef field -> Tuning.server suffix. The table's names predate this file.
const TUNING_SUFFIX := {
	"windup": "windup",
	"recovery": "recovery",
	"cooldown": "cooldown",
	"reach": "range",
	"width": "width",
	"damage": "damage",
	"knock_power": "power",
	"impact_at": "impact_at",
	"catch_window": "catch_window",
	"catch_force": "catch_force",
	"stamina_cost": "stamina",
	"shape_angle_deg": "angle",
	"arc_deg": "arc_deg",
	"speed_bonus": "speed_bonus",
	"height_bonus": "height_bonus",
	"circle_radius": "radius",
	"circle_radius_mastered": "radius_mastered",
	"mastered_stun": "stun",
	"guard_damage_taken": "damage_taken",
	"guard_perfect_window": "perfect_window",
	"guard_reflect_window": "reflect_window",
	"guard_min_hold": "min_hold",
	"guard_move_mult": "move_mult",
}


# M-7: seconds from the cast to the ruling.
# The window a thrown thing is sent back in (see guard_reflect_window).
func guard_reflect_seconds() -> float:
	var window := value("guard_reflect_window")
	return window if window > 0.0 else value("guard_perfect_window")


func impact_time() -> float:
	var at := value("impact_at")
	return at if at > 0.0 else value("windup")


# M-7: how long before the impact a grab catches this.
func catch_window_time() -> float:
	var window := value("catch_window")
	return window if window > 0.0 else float(Tuning.server.catch_window)


# M-7: what a catcher's strength is measured against.
func catch_force_value() -> float:
	var force := value("catch_force")
	return force if force > 0.0 else value("knock_power")


# The number for `field`: the server's slider when the table has it, this
# resource's own value otherwise.
func value(field: String) -> float:
	var number := float(get(field))
	if has_motion() and (field == "windup" or field == "recovery"):
		# Baked off the clip (see "Motion"): the clip's own time, at its pace.
		# The recovery starts at the blow (PlayerSkills._fire), so it holds
		# the swing as well as the way back.
		number = motion_windup / motion_pace() if field == "windup" else _motion_recovery_seconds()
	else:
		for prefix in [tuning_prefix, tuning_fallback_prefix]:
			if prefix == "":
				continue
			var key := "%s_%s" % [prefix, TUNING_SUFFIX.get(field, field)]
			if Tuning.is_server_field(key):
				number = float(Tuning.server.get(key))
				break
	if wielded != null:
		# A weapon's multipliers are named for the slot's skill.
		number *= wielded.mult_for(combo_of if combo_of != "" else id, field)
	return number

# The attack power behind the '피해' coefficient: the weapon in the hand when
# this is a weapon's copy, the skill's own weapon otherwise.
func attack_power() -> float:
	if wielded != null:
		return wielded.attack_power()
	return Weapons.attack_power_for(weapon_id)


func server_intent() -> int:
	return intent if intent >= 0 else ServerAuthority.Intent.SKILL


# C-0: how long the strike bar's swing is shown.
func swing_time() -> float:
	if has_motion():
		return motion_swing / motion_pace()
	return arc_duration if arc_duration > 0.0 else PlayerSkills.STRIKE_SHOW


# ------------------------------------------------------------ the baked motion

func has_motion() -> bool:
	return motion_times.size() >= 2 and motion_path.size() == motion_times.size()


# How many times the clip's own speed the cast runs (the slider, never 0).
func motion_pace() -> float:
	return maxf(value("motion_speed"), 0.05)


# combo_next_at in seconds of the cast (the way back's pace: it is after the blow).
func combo_next_delay() -> float:
	return combo_next_at / motion_back_pace() if has_motion() else combo_next_at


# How long after the blade is through a press still takes the next step.
func combo_press_until() -> float:
	return maxf(maxf(float(Tuning.server.combo_press_after_swing), combo_next_delay()), combo_auto_delay())


# combo_auto_after through its slider: seconds after the blade is through at
# which the next step follows unasked, or -1.
func combo_auto_delay() -> float:
	if combo_auto_after < 0.0:
		return -1.0
	var key := "%s_combo_auto_after" % tuning_prefix
	if tuning_prefix != "" and Tuning.is_server_field(key):
		return maxf(float(Tuning.server.get(key)), 0.0)
	return combo_auto_after


# How many times the clip's speed the way back runs (never 0).
func motion_back_pace() -> float:
	return motion_pace() * maxf(value("motion_recovery_speed"), 0.05)


# The recovery, which starts at the blow: the swing, the clip's way back at
# its own pace, and the step back into the stance where there is one.
func _motion_recovery_seconds() -> float:
	return motion_swing / motion_pace() + motion_recovery / motion_back_pace() + motion_return_seconds()


# The step back into the stance after the clip (see "Motion"), seconds; 0
# for a clip that ends in the stance. The skill's own slider only: a combo
# step does not take its slot skill's.
func motion_return_seconds() -> float:
	if motion_return_foot == "":
		return 0.0
	var seconds := motion_return
	var key := "%s_motion_return" % tuning_prefix
	if tuning_prefix != "" and Tuning.is_server_field(key):
		seconds = float(Tuning.server.get(key))
	return maxf(seconds, 0.0)


# The whole of the body's path, the return included.
func motion_total_seconds() -> float:
	return motion_seconds() + motion_return_seconds()


# The path's length in cast seconds (windup + swing + the clip's way back).
func motion_seconds() -> float:
	if not has_motion():
		return 0.0
	return (motion_windup + motion_swing) / motion_pace() + motion_recovery / motion_back_pace()


# The clip's time (seconds into the source) at `seconds` into the cast: at
# motion_pace up to the end of the swing, at motion_back_pace after it.
func _motion_clip_time(seconds: float) -> float:
	var blow := (motion_windup + motion_swing) / motion_pace()
	var start := motion_times[0]
	if seconds <= blow:
		return start + maxf(seconds, 0.0) * motion_pace()
	return start + motion_windup + motion_swing + (seconds - blow) * motion_back_pace()


# Where the body is `seconds` into the cast, against where it began, as
# (right, up, forward) metres off the aim; and its turn (degrees, + left).
func motion_at(seconds: float) -> Vector3:
	if not has_motion():
		return Vector3.ZERO
	var at := _motion_index(seconds)
	var point := motion_path[at[0]].lerp(motion_path[at[1]], at[2])
	var reach := value("motion_reach")
	var place := Vector3(point.x * reach, point.y, point.z * reach)
	var back := motion_return_seconds()
	if back > 0.0 and seconds > motion_seconds():
		# The step back into the stance: the foot's geometry, not scaled.
		place += motion_return_move * smoothstep(0.0, 1.0, (seconds - motion_seconds()) / back)
	return place


func motion_turn_at(seconds: float) -> float:
	if motion_yaw.size() != motion_times.size() or motion_yaw.is_empty():
		return 0.0
	var at := _motion_index(seconds)
	return lerpf(motion_yaw[at[0]], motion_yaw[at[1]], at[2])


# The fastest the path goes, sample to sample: x across the ground, y up or
# down, metres per cast second. For the server's move check.
func motion_top_speed() -> Vector2:
	var top := Vector2.ZERO
	if not has_motion():
		return top
	var reach := value("motion_reach")
	var blow_end := motion_times[0] + motion_windup + motion_swing
	for index in range(1, motion_times.size()):
		var pace := motion_pace() if motion_times[index - 1] < blow_end - 0.0001 else motion_back_pace()
		var seconds := (motion_times[index] - motion_times[index - 1]) / pace
		if seconds <= 0.0:
			continue
		var moved := motion_path[index] - motion_path[index - 1]
		top.x = maxf(top.x, Vector2(moved.x, moved.z).length() * reach / seconds)
		top.y = maxf(top.y, absf(moved.y) / seconds)
	var back := motion_return_seconds()
	if back > 0.0:
		# A smoothstep's fastest is 1.5 times its mean.
		top.x = maxf(top.x, Vector2(motion_return_move.x, motion_return_move.z).length() * 1.5 / back)
	return top


# Where the cast has taken the body `seconds` after the press, (right, up,
# forward) metres off the aim: the baked path, or the old step
# (step_distance between step_from and step_to of windup + swing). One
# answer for the checks, whichever way the skill moves.
func body_travel_at(seconds: float) -> Vector3:
	if has_motion():
		return motion_at(seconds)
	var cast := value("windup") + swing_time()
	if step_distance <= 0.0 or cast <= 0.0:
		return Vector3.ZERO
	var start := clampf(step_from, 0.0, 0.95)
	var span := maxf(clampf(step_to, 0.0, 1.0) - start, 0.05)
	return Vector3(0.0, 0.0, step_distance * clampf((seconds / cast - start) / span, 0.0, 1.0))


# The furthest ahead the cast takes the body, at any moment of it.
func travel_most() -> float:
	if not has_motion():
		return step_distance
	var most := 0.0
	for point in motion_path:
		most = maxf(most, point.z * value("motion_reach"))
	if motion_return_seconds() > 0.0:
		most = maxf(most, motion_at(motion_total_seconds()).z)
	return most


# How far the path takes the body off the height it started at, up or down:
# a cast that leaves the ground, or (2026-11-22, the rising cut's dive) one
# that starts in the air and drives the body down.
func motion_lift() -> float:
	var top := 0.0
	for point in motion_path:
		top = maxf(top, absf(point.y))
	return top


# [before, after, weight] for a moment of the cast on the sample times.
func _motion_index(seconds: float) -> Array:
	var clip_time := _motion_clip_time(seconds)
	var last := motion_times.size() - 1
	if clip_time >= motion_times[last]:
		return [last, last, 0.0]
	var index := motion_times.bsearch(clip_time, true)
	index = clampi(index, 1, last)
	var span := motion_times[index] - motion_times[index - 1]
	var weight := 0.0 if span <= 0.0 else (clip_time - motion_times[index - 1]) / span
	return [index - 1, index, clampf(weight, 0.0, 1.0)]


# C-1g-a: the swing's angle, degrees, through value() (a sword skill's is
# the server's slider).
func arc_degrees() -> float:
	return value("arc_deg")


# An arc of zero is a thrust: the bar is pushed out, not turned.
func is_thrust_motion() -> bool:
	return arc_degrees() < 0.01


# +1 turns the positive way (left / up), -1 the other.
func arc_sign() -> float:
	return -1.0 if arc_reversed else 1.0


# Where the pivot is at the start of the swing, degrees.
func arc_start() -> float:
	if arc_centred:
		return -arc_sign() * arc_degrees() * 0.5
	return arc_start_deg


func arc_end() -> float:
	return arc_start() + arc_sign() * arc_degrees()


# The swing's easing: fast out of the start, settling at the end. One
# function so the picture (Player._pose_swing) and the ruling
# (ServerAuthority's sweep) put the blade in the same place at the same
# progress.
static func swing_eased(p: float) -> float:
	var c := clampf(p, 0.0, 1.0)
	return 1.0 - (1.0 - c) * (1.0 - c)


# The pivot's angle at progress p (0..1), degrees.
func swing_angle_deg(p: float) -> float:
	return arc_start() + arc_sign() * arc_degrees() * swing_eased(p)


# C-0: whether the key shows a shape on the ground before the cast.
func shows_range() -> bool:
	return range_shape != RangeShape.NONE and input_mode == InputMode.PRESS_CAST


# C-1c: the circle's radius through value(), so a slider-backed one (the
# shield slam's shield_slam_radius) is what the server rules with.
# 2026-11-24: `level` is the caster's mastery of the skill (-1: not asked);
# from mastered_level the disc is circle_radius_mastered wide.
func circle_radius_value(level := -1) -> float:
	if is_mastered(level) and value("circle_radius_mastered") > 0.0:
		return value("circle_radius_mastered")
	return value("circle_radius")


# 2026-11-24 (the user): what a skill gains at a mastery of its own, without
# becoming another skill: from mastered_level (-1: nothing) its disc is
# circle_radius_mastered and a body it hits is held still mastered_stun
# seconds. Sliders: <tuning_prefix>_radius_mastered / _stun.
@export var mastered_level: int = -1
@export var circle_radius_mastered: float = 0.0
@export var mastered_stun: float = 0.0


func is_mastered(level: int) -> bool:
	return mastered_level >= 0 and level >= mastered_level


# What the path's height is multiplied by for a body whose leap is `height`
# metres (lift_by_ratio); 1 for every other skill.
func lift_scale(height: float) -> float:
	var top := motion_lift()
	if not lift_by_ratio or top <= 0.0:
		return 1.0
	return maxf(height, 0.0) / top
