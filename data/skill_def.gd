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
}

# M-6: how the key is read. PRESS_CAST is the cast flow (arm or cast on the
# press, windup, ruling, recovery). HOLD_RELEASE is the grab's: the press is
# the request (or, with something in hand, the start of a charge), the release
# decides -- under the threshold a put-down, over it an arc, Shift a line. The
# smart key and the left button play no part in it.
enum InputMode {
	PRESS_CAST,
	HOLD_RELEASE,
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
@export var knock_power: float = 0.0
# C-1a: the '스태미나' column. A fixed cost per cast; 0 stamina refuses the
# cast at the intent (C-1b/C-1d spend it, this stage carries it).
@export var stamina_cost: float = 0.0
# C-1a: damage itself never stuns (only a launch does); a skill that says so
# here stuns for this long on a hit. 0 for everything in C-1 but the parry.
@export var stun_on_hit: float = 0.0
@export var attack_tag: AttackTag = AttackTag.PHYSICAL
@export var holy: bool = false
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

@export_group("Display")
# The procedural show: how far the capsule leans into the windup and back out
# of the recovery, and the bar that is the strike -- how far it reaches and
# how high it sits. No rigs, no clips.
@export var windup_lean_deg: float = 14.0
@export var recovery_lean_deg: float = -6.0
@export var strike_extent: float = 0.8
@export var strike_height: float = 0.3
@export var colour: Color = Color("ffd166")

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
# it; over arc_duration seconds the pivot turns from arc_start_deg through
# arc_sweep_deg in arc_plane, leaving a trail. Horizontal: positive is to the
# body's left. Vertical: positive is up. A sweep of zero is a thrust, which
# pushes the bar out along the heading instead of turning it. arc_duration 0
# means PlayerSkills.STRIKE_SHOW. The sword's four get their numbers in C-1b;
# the bare four and the scarecrow's slam carry theirs here.
@export var arc_plane: ArcPlane = ArcPlane.HORIZONTAL
@export var arc_start_deg: float = 0.0
@export var arc_sweep_deg: float = 0.0
@export var arc_duration: float = 0.0
@export var trail: bool = true

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
}


# M-7: seconds from the cast to the ruling.
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
	if tuning_prefix != "":
		var key := "%s_%s" % [tuning_prefix, TUNING_SUFFIX.get(field, field)]
		if Tuning.is_server_field(key):
			return float(Tuning.server.get(key))
	return float(get(field))


func server_intent() -> int:
	return intent if intent >= 0 else ServerAuthority.Intent.SKILL


# C-0: how long the strike bar's swing is shown.
func swing_time() -> float:
	return arc_duration if arc_duration > 0.0 else PlayerSkills.STRIKE_SHOW


# C-0: whether the key shows a shape on the ground before the cast.
func shows_range() -> bool:
	return range_shape != RangeShape.NONE and input_mode == InputMode.PRESS_CAST
