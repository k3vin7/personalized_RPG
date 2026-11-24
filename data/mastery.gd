extends RefCounted

# Not a class_name: a new global class is not seen by a run until the editor
# has rescanned. Users preload it (const Mastery := preload(...)).
#
# 2026-11-20: how far a body has mastered a skill, and the form the skill takes
# for it (SkillDef.form_levels / form_skills). Mastery is a ruling -- the
# server decides which form a cast may be -- so the number is the server's.
# Until mastery is earned it is one slider for everyone
# (Tuning.server.mastery_debug_level); the owner reads the same replicated
# table, so both sides pick the same form.


static func level_of(_actor: Node, _skill_id: String) -> int:
	return int(Tuning.server.mastery_debug_level)


# The skill a slot holding `def` casts for this body now: its highest form the
# body's mastery reaches, or itself. The form is copied for the hands the way
# the slot's skill was (Skills.for_holder).
static func form_for(def: SkillDef, actor: Node, main_kind: int, off_kind: int) -> SkillDef:
	if def == null or def.form_skills.is_empty():
		return def
	var level := level_of(actor, def.id)
	var chosen := ""
	var best := -1
	for index in mini(def.form_levels.size(), def.form_skills.size()):
		var needs := def.form_levels[index]
		if level >= needs and needs > best:
			best = needs
			chosen = def.form_skills[index]
	if chosen == "":
		return def
	var form := Skills.for_holder(chosen, main_kind, off_kind)
	return form if form != null else def


# The server's check on a cast that claims to be a form.
static func allows(def: SkillDef, actor: Node) -> bool:
	if def == null or def.form_of == "":
		return true
	return level_of(actor, def.form_of) >= def.form_level


# The step a combo goes on to for this body: def.combo_next, or none when
# that step asks for more mastery than the body has (2026-11-24: the rising
# cut is one blow at 0; from 1 its dive follows, and that is the last step;
# from 2 the dive's disc is wider and it stuns -- SkillDef.mastered_level, not
# a step). Both sides ask this, so the owner never offers a step the server
# would refuse.
static func next_step(def: SkillDef, actor: Node) -> String:
	if def == null or def.combo_next == "":
		return ""
	return def.combo_next if allows(Skills.get_def(def.combo_next), actor) else ""
