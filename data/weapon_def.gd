class_name WeaponDef
extends Resource

# C-1a: a weapon as data. Attack power and what it asks of the hands. A
# skill's damage is its coefficient times this weapon's attack power; the
# power itself is a Tuning.server slider named by attack_field (the tracker's
# numbers are temporary), so this file only names the weapon.

@export var id: String = ""
@export var label: String = ""
# Which WeaponKinds.Kind this is, for the rack and the slot layout.
@export var kind: int = WeaponKinds.Kind.NONE
@export var hands: SkillDef.Hands = SkillDef.Hands.BARE
# The slider: Tuning.server.<attack_field>. Empty means attack_power_value.
@export var attack_field: String = ""
@export var attack_power_value: float = 1.0
# C-1b: the four skills this weapon puts in the main hand's slots, in slot
# order. Empty for a weapon whose skills are a later stage's (bow, spear,
# staff) and for bare hands (Skills.BARE_IDS fills those).
@export var skill_ids: PackedStringArray = PackedStringArray()

@export_group("Variant")
# The weapon id whose skills and handling this one shares ("sword" for the
# great sword). Empty: the weapon is its own family. A skill asks for a
# family (SkillDef.weapon_id), so every member of it casts the same four.
@export var family: String = ""
# Tuning.server.<tuning_prefix>_<name> is the number behind `name` below
# (weight, reach_mult, ...); the value here is what ships when the table has
# no such slider. Judgement values, so the server's (CLAUDE.md 12).
@export var tuning_prefix: String = ""
# Hilt to tip along the hand's -Z, metres. A family member's is the family's
# length x its "*.reach" multiplier, so the tip stays on the range's edge.
@export var length: float = 0.0
# Kilograms on the body while it is in a hand (CharacterStats.weapon_weight),
# and the weight of the body it becomes when thrown.
@export var weight: float = 0.0
# How a skill's numbers change in this weapon's hand: "<skill id>.<SkillDef
# field>" or "*.<field>" -> the name of the multiplier (one of the numbers
# below, or its slider). SkillDef.value() applies it; nothing else does.
@export var skill_mults: Dictionary = {}
@export var reach_mult: float = 1.0
@export var windup_mult: float = 1.0
@export var width_mult: float = 1.0
@export var block_mult: float = 1.0
# The picture only: the stand-in's size beside its family's.
@export var visual_scale: float = 1.0


func attack_power() -> float:
	if attack_field != "" and Tuning.is_server_field(attack_field):
		return float(Tuning.server.get(attack_field))
	return attack_power_value


func family_id() -> String:
	return family if family != "" else id


# The number called `field`: the server's slider when the table has one,
# this resource's own value otherwise.
func number(field: String) -> float:
	if tuning_prefix != "":
		var key := "%s_%s" % [tuning_prefix, field]
		if Tuning.is_server_field(key):
			return float(Tuning.server.get(key))
	return float(get(field))


# What `field` of the skill `skill_id` is multiplied by in this hand.
func mult_for(skill_id: String, field: String) -> float:
	var named: String = skill_mults.get("%s.%s" % [skill_id, field], skill_mults.get("*.%s" % field, ""))
	return number(named) if named != "" else 1.0


func length_value() -> float:
	if family == "" or family == id:
		return length
	var base := Weapons.get_def(family)
	return (base.length_value() if base != null else length) * mult_for("*", "reach")


func weight_value() -> float:
	return number("weight")


# The stand-in's size beside its family's: the blade's ratio for a weapon
# with a length, visual_scale for the rest.
func size_ratio() -> float:
	var base := Weapons.get_def(family_id())
	if base != null and base != self and base.length_value() > 0.0:
		return length_value() / base.length_value()
	return visual_scale
