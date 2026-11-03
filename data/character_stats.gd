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

# C-1a: the allocated points, one count per ability in Ability order. An
# ability is the race's number plus points x Tuning.server.stat_point_weight.
# Levels and the points themselves are C-5's; this stage only has the shape,
# and every body is at zero. Written only by the server (the Vitals
# synchronizer carries it), like the race.
enum Ability {
	STRENGTH,
	ENDURANCE,
	AGILITY,
	INTELLECT,
	VITALITY,
}
@export var points: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0])

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
		var base := strength_override if not is_nan(strength_override) else race_data().strength
		return base + point_bonus(Ability.STRENGTH)

var race_weight: float:
	get:
		return weight_override if not is_nan(weight_override) else race_data().body_weight

var endurance: float:
	get:
		return race_data().endurance + point_bonus(Ability.ENDURANCE)

var agility: float:
	get:
		return race_data().agility + point_bonus(Ability.AGILITY)

var intellect: float:
	get:
		return race_data().intellect + point_bonus(Ability.INTELLECT)

# C-1a: the fifth ability, which HP comes out of.
var vitality: float:
	get:
		return race_data().vitality + point_bonus(Ability.VITALITY)


# C-1a: what the allocated points add to one ability. The weight is the
# server's slider; the points are the server's too.
func point_bonus(ability: int) -> float:
	if ability < 0 or ability >= points.size():
		return 0.0
	return float(points[ability]) * Tuning.server.stat_point_weight


# The race's own number for an ability, with no points and no override: the
# crit chance reads agility against this.
func base_agility() -> float:
	return race_data().agility

var height_cm: float:
	get:
		return race_data().height_cm

# H-3: derived, like the abilities above. The coefficients are in the server's
# tuning table (Tuning.server), which on a client is a replica only the server's
# push may write -- so a client that moves its own slider changes nothing about
# how much it can take. C-1a: HP = vitality x k_hp (H-3 had it on endurance);
# stamina = endurance x (1 + alpha). A human is 105 / 101.5.
var max_hp: float:
	get:
		return vitality * Tuning.server.k_hp

var max_stamina: float:
	get:
		return endurance * (1.0 + Tuning.server.stamina_alpha)


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


func clear_points() -> void:
	points = PackedInt32Array([0, 0, 0, 0, 0])
