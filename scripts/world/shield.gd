class_name Shield
extends Rock

# C-1c: a thrown shield, as a body. A rock in every rule -- the same sphere
# collision, the same layer, the same throw and hit door, the same hold table
# -- with three differences and no more: the picture (a plank, not a sphere),
# the weight (Tuning.server.shield_weight), and what picking it up means (the
# grab key on it puts it back in an empty off hand, ServerAuthority._rule_grab,
# instead of lifting it). Spawned by the host when one is thrown and told to
# every peer by RPC (code-built nodes do not replicate, CLAUDE.md 1); its
# position then travels on Rock's push_state like any rock's.

func _ready() -> void:
	super()
	if _label != null:
		_label.text = "방패 %.0fkg" % weight


func _build_visual(_radius: float) -> void:
	var plank := WeaponKinds.build_mesh(WeaponKinds.Kind.SHIELD)
	# The rack's shield stands on edge facing -Z; on the ground it lies flat.
	plank.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	add_child(plank)


func _hit_def() -> SkillDef:
	return Skills.get_def("shield_throw")


func _hit_power(_speed: float) -> float:
	var def := _hit_def()
	return def.value("knock_power") if def != null else 0.0
