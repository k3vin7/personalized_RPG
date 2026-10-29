class_name Races
extends RefCounted

# The one place a race id turns into numbers. Every peer loads the same four
# resources, so a race only has to travel as an id: the values behind it are
# not something anyone is told, which is what makes them the server's.

enum Kind {
	HUMAN,
	ELF,
	DWARF,
	ORC,
}

const PATHS := {
	Kind.HUMAN: "res://data/races/human.tres",
	Kind.ELF: "res://data/races/elf.tres",
	Kind.DWARF: "res://data/races/dwarf.tres",
	Kind.ORC: "res://data/races/orc.tres",
}

# v4: a peer that has just connected is human until it stands on a pedestal.
const DEFAULT := Kind.HUMAN

static var _cache := {}


static func data_for(kind: int) -> RaceData:
	if not PATHS.has(kind):
		kind = DEFAULT
	if not _cache.has(kind):
		var loaded := load(PATHS[kind]) as RaceData
		if loaded == null:
			# Better a visible default than a null every formula has to test.
			push_error("Races: %s would not load" % PATHS[kind])
			loaded = RaceData.new()
		_cache[kind] = loaded
	return _cache[kind] as RaceData


static func is_known(kind: int) -> bool:
	return PATHS.has(kind)


static func label_for(kind: int) -> String:
	var data := data_for(kind)
	return data.label if data.label != "" else "race %d" % kind


static func all_kinds() -> Array:
	return PATHS.keys()
