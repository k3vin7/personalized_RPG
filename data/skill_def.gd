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
@export var damage: float = 0.0
@export var knock_power: float = 0.0
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
# of the recovery, and the box that is the strike -- how far it reaches and
# how high it sits. No rigs, no clips.
@export var windup_lean_deg: float = 14.0
@export var recovery_lean_deg: float = -6.0
@export var strike_extent: float = 0.8
@export var strike_height: float = 0.3
@export var colour: Color = Color("ffd166")

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
