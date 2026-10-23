extends Node

# Holds the one PhysicsTuning resource everything reads from, plus the single
# strength-to-weight formula the work order requires every calculation to go
# through. Nothing else may reimplement it.

const TUNING_PATH := "res://data/physics_tuning.tres"

signal tuning_changed()

var values: PhysicsTuning


func _ready() -> void:
	var loaded := load(TUNING_PATH) as PhysicsTuning
	# Duplicated on purpose: tuning edits are local to each peer so two people
	# can experiment side by side. The debug panel has a button to pull the
	# host's numbers when they want to compare like for like.
	values = loaded.duplicate(true) if loaded != null else PhysicsTuning.new()


# ratio_mult(ratio, k) = clamp(1 + k * ln(ratio), min, max)
# Log so that a bigger ratio keeps helping but with falling returns, and so the
# default ratio of 1.0 lands exactly on a multiplier of 1.0.
func ratio_mult(ratio: float, k: float) -> float:
	return clampf(1.0 + k * log(maxf(ratio, 0.0001)), values.ratio_mult_min, values.ratio_mult_max)


func notify_changed() -> void:
	tuning_changed.emit()
