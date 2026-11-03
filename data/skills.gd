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
	# C-1b: the sword's four. Which weapon holds them is the WeaponDef's
	# (skill_ids), not a list here.
	"thrust": "res://data/skills/thrust.tres",
	"side_cut": "res://data/skills/side_cut.tres",
	"overhead_cut": "res://data/skills/overhead_cut.tres",
	"parry": "res://data/skills/parry.tres",
	# C-1c: the shield's four.
	"shield_raise": "res://data/skills/shield_raise.tres",
	"shield_bash": "res://data/skills/shield_bash.tres",
	"shield_throw": "res://data/skills/shield_throw.tres",
	"shield_slam": "res://data/skills/shield_slam.tres",
}

# What an empty hand can do, in slot order.
const BARE_IDS := ["shove", "grab", "punch", "kick"]

static var _cache := {}


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
