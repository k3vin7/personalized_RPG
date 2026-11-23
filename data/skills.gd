class_name Skills
extends RefCounted

# The one place a skill id turns into a SkillDef. Every peer loads the same
# resources, so a slot only has to say which id it holds; the numbers behind it
# are the server's sliders or the shared file, never something a peer is told.

const PATHS := {
	"shove": "res://data/skills/shove.tres",
	"grab": "res://data/skills/grab.tres",
	"punch": "res://data/skills/punch.tres",
	"kick": "res://data/skills/kick.tres",
	# M-7: the scarecrow's one attack, a stand-in for a boss swing.
	"dummy_slam": "res://data/skills/dummy_slam.tres",
	# 2026-11-22: the sword scarecrow's cut (SwordDummy).
	"dummy_sword_cut": "res://data/skills/dummy_sword_cut.tres",
	# 늑대 a: the wolf's bite. Never in a player's slot.
	"wolf_bite": "res://data/skills/wolf_bite.tres",
	# C-1b: the sword's four. Which weapon holds them is the WeaponDef's
	# (skill_ids), not a list here.
	"thrust": "res://data/skills/thrust.tres",
	# 2026-11-18: the thrust's second step, the push kick that frees the
	# blade. Bare numbers (the kick's): it is the foot that lands.
	"thrust_2": "res://data/skills/thrust_2.tres",
	# 2026-11-23 (the user): a thrust that landed stays in; its own key, or
	# nothing pressed, pulls the blade out, which cuts again (thrust_2, the
	# push kick, is out of the chain; its file stays for the checks).
	"thrust_pull": "res://data/skills/thrust_pull.tres",
	# 2026-11-23: the thrust's key on a monster's back: the stab down.
	"back_stab": "res://data/skills/back_stab.tres",
	"side_cut": "res://data/skills/side_cut.tres",
	# 2026-11-18: the side cut's second step. Never in a slot: the side cut
	# pressed again while it is going casts it. (A third step was taken out
	# on 2026-11-19.)
	"side_cut_2": "res://data/skills/side_cut_2.tres",
	# Out of the sword's slots since 2026-11-19 (the dash cut took its place);
	# the file and its numbers stay for the checks that cast it by name.
	"overhead_cut": "res://data/skills/overhead_cut.tres",
	# 2026-11-19: low, the sword hand at the left hip, then gone along a
	# straight line and through whatever stood on it.
	"dash_cut": "res://data/skills/dash_cut.tres",
	# 2026-11-20: the rising cut took the dash cut's slot (the user's call;
	# the dash cut's file and numbers stay). 2026-11-22: Attack_Rising, and
	# at mastery 2 the dive from the top of its leap (m2).
	"rising_cut": "res://data/skills/rising_cut.tres",
	"rising_cut_m2": "res://data/skills/rising_cut_m2.tres",
	# 2026-11-22: the sword's fourth slot is the held block (sword_guard);
	# the tapped parry's file and ruling stay, in no slot.
	"parry": "res://data/skills/parry.tres",
	"sword_guard": "res://data/skills/sword_guard.tres",
	# 2026-11-22: the sword guard's counter (mastery 2), cast from the side
	# cut's slot right after a perfect guard.
	"counter_cut": "res://data/skills/counter_cut.tres",
	# C-1c: the shield's four.
	"shield_raise": "res://data/skills/shield_raise.tres",
	"shield_bash": "res://data/skills/shield_bash.tres",
	"shield_throw": "res://data/skills/shield_throw.tres",
	"shield_slam": "res://data/skills/shield_slam.tres",
}

# What an empty hand can do, in slot order.
const BARE_IDS := ["shove", "grab", "punch", "kick"]

static var _cache := {}
static var _variants := {}


static func get_def(id: String) -> SkillDef:
	if not PATHS.has(id):
		return null
	if not _cache.has(id):
		var loaded := load(PATHS[id]) as SkillDef
		if loaded == null:
			push_error("Skills: %s would not load" % PATHS[id])
			return null
		_cache[id] = loaded
	return _cache[id] as SkillDef


static func is_known(id: String) -> bool:
	return PATHS.has(id)


static func all_ids() -> Array:
	return PATHS.keys()


# The skill as the body holding these two kinds casts it. A weapon's skill in
# the hand of a member of that weapon's family (the great sword's thrust) is
# the same skill with that weapon's multipliers on its numbers: one copy per
# (skill, weapon), with SkillDef.wielded set, so every def.value() down the
# line -- the server's ruling, the range on the ground, the hand -- reads the
# same scaled number. Bare skills and the family's own weapon are the file.
static func for_holder(id: String, main_kind: int, off_kind: int) -> SkillDef:
	var base := get_def(id)
	if base == null or base.weapon_id == "bare":
		return base
	for kind: int in [main_kind, off_kind]:
		var weapon := Weapons.def_for_kind(kind)
		if weapon == null or weapon.family_id() != base.weapon_id:
			continue
		if weapon.id == base.weapon_id:
			return base
		var key := "%s@%s" % [id, weapon.id]
		if not _variants.has(key):
			var copy := base.duplicate() as SkillDef
			copy.wielded = weapon
			_variants[key] = copy
		return _variants[key] as SkillDef
	return base


# The file's def and every weapon's copy of it: a local slider that moves a
# drawn-only field writes them all.
static func every_copy(id: String) -> Array[SkillDef]:
	var out: Array[SkillDef] = []
	var base := get_def(id)
	if base != null:
		out.append(base)
	for key: String in _variants:
		if key.begins_with(id + "@"):
			out.append(_variants[key])
	return out
