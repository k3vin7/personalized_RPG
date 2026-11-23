class_name SwordDummy
extends Dummy

# 2026-11-22 (the user): a scarecrow with a sword. Not on a timer like the
# slam: when a person comes within dummy_sword_approach it turns to them,
# shows its cut on the ground (the same telegraph, a fan) and cuts, then
# rests dummy_sword_rest before the next. The cut is booked with the judge at
# the start of the windup like the slam, so it can be guarded, caught or
# perfectly guarded (which holds it still). Everything else -- the push,
# the lift, the walk home, the state on the wire -- is the scarecrow's.

var _rest_left := 0.0
var _sword: Node3D


func attack_def() -> SkillDef:
	return Skills.get_def("dummy_sword_cut")


func base_colour() -> Color:
	return Color("b8a47c")


func race_label() -> String:
	return "검 허수아비"


func anchored() -> bool:
	return bool(Tuning.server.dummy_sword_anchored)


func _ready() -> void:
	super._ready()
	# The sword in its right hand, blade forward and down a little.
	_sword = WeaponKinds.build_mesh(WeaponKinds.Kind.SWORD)
	_sword.name = "Sword"
	_sword.position = Vector3(RADIUS + 0.05, 0.1, -0.1)
	_sword.rotation_degrees = Vector3(-20.0, 0.0, 0.0)
	add_child(_sword)


func _attack_step(delta: float) -> void:
	if not Tuning.server.dummy_sword_enabled or holder_peer != 0 or ServerAuthority.instance == null:
		if attack_phase != "":
			_set_attack_phase("")
		return
	var def := attack_def()
	if def == null:
		return
	match attack_phase:
		"":
			_rest_left = maxf(0.0, _rest_left - delta)
			if _rest_left > 0.0:
				return
			var target := _nearest_person(float(Tuning.server.dummy_sword_approach))
			if target == null:
				return
			var toward := target.global_position - global_position
			toward.y = 0.0
			if toward.length_squared() > 0.0001:
				rotation.y = atan2(-toward.x, -toward.z)
			_phase_left = def.impact_time()
			_set_attack_phase("windup")
			ServerAuthority.instance.schedule_strike(self, def, attack_direction())
			attacks_made += 1
		"windup":
			_phase_left -= delta
			if _phase_left <= 0.0:
				_phase_left = def.value("recovery")
				_set_attack_phase("recovery")
		"recovery", "stunned":
			_phase_left -= delta
			if _phase_left <= 0.0:
				_rest_left = float(Tuning.server.dummy_sword_rest)
				_set_attack_phase("")


# The closest living person on the ground within `reach` (flat distance).
func _nearest_person(reach: float) -> Player:
	if Net.spawn_root == null:
		return null
	var best: Player = null
	var best_gap := reach
	for node in Net.spawn_root.get_children():
		var person := node as Player
		if person == null or person.sync_dead:
			continue
		var gap := Vector2(person.global_position.x - global_position.x, person.global_position.z - global_position.z).length()
		if gap <= best_gap:
			best_gap = gap
			best = person
	return best
