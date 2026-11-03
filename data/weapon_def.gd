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


func attack_power() -> float:
	if attack_field != "" and Tuning.is_server_field(attack_field):
		return float(Tuning.server.get(attack_field))
	return attack_power_value
