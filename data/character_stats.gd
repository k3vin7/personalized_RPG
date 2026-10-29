class_name CharacterStats
extends Resource

# What a body is, derived rather than stored. The race id and the debug
# overrides are the only state; every ability comes out of the race resource,
# which every peer has. That is what lets the race travel as one id and still
# leave the numbers behind it the server's: a client cannot state its own
# strength, only which pedestal it stood on, and the server rules on that.
#
# H-1 moved these off the owner's synchronizer onto the server's. Nothing here
# is written by a client any more -- not even its own.

# v4: everyone starts human.
@export var race: int = Races.DEFAULT

# The debug sliders, which v4 keeps: they sit on top of the race's values so a
# number can be swept without inventing a race for it. NAN means "follow the
# race", which is what choosing a race again restores. Written only by the
# server, through ServerAuthority -- the slider sends an intent.
@export var strength_override: float = NAN
@export var weight_override: float = NAN

@export var gear_weight: float = 0.0
@export var max_hp: float = 100.0

# Stage E: what this body is carrying. Not exported -- it is set by the hold,
# not by the character sheet -- but it is part of the weight every formula in
# 4-chapter reads, which is how carrying something makes a body slower and its
# jump lower without a single rule of its own.
var held_weight: float = 0.0


func race_data() -> RaceData:
	return Races.data_for(race)


# The abilities. Read-only on purpose: the old `stats.strength = n` wrote a
# number nobody had ruled on, and on a client it wrote one the server then
# believed. Setting one now means setting the override, which goes through
# ServerAuthority.
var strength: float:
	get:
		return strength_override if not is_nan(strength_override) else race_data().strength

var race_weight: float:
	get:
		return weight_override if not is_nan(weight_override) else race_data().body_weight

var endurance: float:
	get:
		return race_data().endurance

var agility: float:
	get:
		return race_data().agility

var intellect: float:
	get:
		return race_data().intellect

var height_cm: float:
	get:
		return race_data().height_cm


func total_weight() -> float:
	return race_weight + gear_weight + held_weight


func ratio() -> float:
	return strength / maxf(total_weight(), 0.1)


# True while a slider is holding this body off its race's own numbers, which is
# what the debug panel shows and what choosing a race clears.
func is_overridden() -> bool:
	return not is_nan(strength_override) or not is_nan(weight_override)


func clear_overrides() -> void:
	strength_override = NAN
	weight_override = NAN
