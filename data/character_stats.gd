class_name CharacterStats
extends Resource

# Per character, and synchronised: a shove is computed from the pusher's
# strength against the target's weight, so every peer needs the target's
# numbers to agree.

@export var strength: float = 10.0
@export var race_weight: float = 10.0
@export var gear_weight: float = 0.0
@export var max_hp: float = 100.0


func total_weight() -> float:
	return race_weight + gear_weight


func ratio() -> float:
	return strength / maxf(total_weight(), 0.1)
