class_name Weapons
extends RefCounted

# The one place a weapon id turns into a WeaponDef. Every peer loads the same
# files; the attack powers behind them are the server's sliders.

const PATHS := {
	"bare": "res://data/weapons/bare.tres",
	"sword": "res://data/weapons/sword.tres",
	"shield": "res://data/weapons/shield.tres",
}

static var _cache := {}


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


# The attack power a skill multiplies its coefficient by. An unknown weapon
# reads as bare hands (1), never as nothing.
static func attack_power_for(id: String) -> float:
	var def := get_def(id)
	return def.attack_power() if def != null else 1.0
