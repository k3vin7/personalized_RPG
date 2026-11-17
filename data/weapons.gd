class_name Weapons
extends RefCounted

# The one place a weapon id turns into a WeaponDef. Every peer loads the same
# files; the attack powers behind them are the server's sliders.

const PATHS := {
	"bare": "res://data/weapons/bare.tres",
	"sword": "res://data/weapons/sword.tres",
	"shield": "res://data/weapons/shield.tres",
	# No skills yet (their stages); here so a race's list can name them.
	"bow": "res://data/weapons/bow.tres",
	"spear": "res://data/weapons/spear.tres",
	"staff": "res://data/weapons/staff.tres",
	# Family members: the same skills as their family, other numbers. Who may
	# hold them is the race's list (RaceData.usable_weapons).
	"great_sword": "res://data/weapons/great_sword.tres",
	"great_shield": "res://data/weapons/great_shield.tres",
}

static var _cache := {}
static var _by_kind := {}


static func get_def(id: String) -> WeaponDef:
	if not PATHS.has(id):
		return null
	if not _cache.has(id):
		var loaded := load(PATHS[id]) as WeaponDef
		if loaded == null:
			push_error("Weapons: %s would not load" % PATHS[id])
			return null
		_cache[id] = loaded
	return _cache[id] as WeaponDef


static func is_known(id: String) -> bool:
	return PATHS.has(id)


static func all_ids() -> Array:
	return PATHS.keys()


# C-1b: the WeaponDef behind a WeaponKinds.Kind, for the slot layout. None
# for a kind no def names (bow, spear, staff until their stages).
static func def_for_kind(kind: int) -> WeaponDef:
	if kind == WeaponKinds.Kind.NONE:
		return null
	if _by_kind.is_empty():
		for id in PATHS:
			var def := get_def(id)
			if def != null and def.kind != WeaponKinds.Kind.NONE:
				_by_kind[def.kind] = def
	return _by_kind.get(kind) as WeaponDef


# The family's weapon behind a kind: the sword for the great sword, itself
# for a weapon that is its own family. What the code asks instead of "is
# this the sword": every member of a family is handled the same way.
static func family_def(kind: int) -> WeaponDef:
	var def := def_for_kind(kind)
	if def == null:
		return null
	var base := get_def(def.family_id())
	return base if base != null else def


static func family_kind(kind: int) -> int:
	var base := family_def(kind)
	return base.kind if base != null else kind


static func family_id_of(kind: int) -> String:
	var def := def_for_kind(kind)
	return def.family_id() if def != null else ""


# Whether this kind goes to the off hand (the shield's family).
static func is_off_hand(kind: int) -> bool:
	var def := def_for_kind(kind)
	return def != null and def.hands == SkillDef.Hands.OFF_HAND


static func length_of(kind: int) -> float:
	var def := def_for_kind(kind)
	return def.length_value() if def != null else 0.0


static func weight_of(kind: int) -> float:
	var def := def_for_kind(kind)
	return def.weight_value() if def != null else 0.0


static func size_ratio_of(kind: int) -> float:
	var def := def_for_kind(kind)
	return def.size_ratio() if def != null else 1.0


# Whether a body of this race may take this kind in hand: the race's own
# list. Empty hands are everyone's.
static func usable_by(race: int, kind: int) -> bool:
	if kind == WeaponKinds.Kind.NONE:
		return true
	var def := def_for_kind(kind)
	return def != null and Races.data_for(race).can_use(def.id)


# The attack power a skill multiplies its coefficient by. An unknown weapon
# reads as bare hands (1), never as nothing.
static func attack_power_for(id: String) -> float:
	var def := get_def(id)
	return def.attack_power() if def != null else 1.0
