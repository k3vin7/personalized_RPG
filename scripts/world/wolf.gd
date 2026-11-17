class_name Wolf
extends Dummy

# 늑대 a: one wolf. A scarecrow in every rule the judge applies -- the same
# apply_hit, the same force event, the same knockback verdict, the same hold
# table, the same booked strike and the same telegraph -- with a brain of its
# own in place of the scarecrow's walk home, and a death.
#
# The server decides everything here: who it has noticed, when it bites and
# where the bite goes. Every other screen is shown the position, the heading,
# the HP and the phase that Dummy.push_state carries.
#
#   idle    strolls near its mark
#   chase   a living player inside wolf_aggro_range, or whoever hit it last
#   bite    inside wolf_bite_start_range it stops, shows the path for the
#           windup, then leaps along it (the judge rules the path at the end
#           of the windup, where the telegraph is full) and cannot move for
#           the recovery
#   return  wolf_leash_range from its mark it walks back, deaf until it is home
#
# Being hit does not stop it: a push it holds against slides it and the bite
# goes on. A push past its tolerance throws it, and a body in the air has
# nothing to leap from, so that does end the bite.
#
# At 0 HP the body is gone on every screen and a carcass (WolfCorpse, a rock
# in every rule) lies where it fell for wolf_corpse_time.

enum Mode {
	IDLE,
	CHASE,
	RETURN,
}

# The picture: a capsule on its side, nose along -Z. The shape is temporary
# like every other body's; the numbers that are judged with (weight, strength,
# HP, speeds, ranges) are Tuning.server's.
const BODY_RADIUS := 0.35
const BODY_LENGTH := 1.3
# What the judge's rectangles add for this body: between its half width and
# its half length.
const HIT_RADIUS := 0.5
const BASE_COLOUR := Color("8a8d91")
# How close to its mark counts as home, and to a stroll's end as arrived.
const HOME_RADIUS := 1.0
const WANDER_ARRIVE := 0.3
# A stroll that has not arrived by now (something in the way) is given up.
const WANDER_LEG_MAX := 6.0
const TURN_RATE := 10.0
# Under this a push has run out and the legs take over again (m/s).
const PUSH_SETTLED := 0.5
# The killing blow's push is applied a step after its damage (ForceSystem
# queues it), so the body stays for this many steps and the carcass leaves
# with the speed the blow gave it.
const DEATH_STEPS := 3

var mode := Mode.IDLE
# Who it is after: the peer it noticed, replaced by whoever hits it.
var target_peer := 0
var bites_started := 0
var corpses_made := 0
var deaths := 0

var _bite_direction := Vector3.FORWARD
var _pushed := false
var _wander_to := Vector3.ZERO
var _wander_wait := 0.0
var _wander_left := 0.0
var _dying := 0
var _dead := false
var _corpse_name := ""
var _corpse_left := 0.0


func max_hp() -> float:
	return Tuning.server.wolf_max_hp


func weight() -> float:
	return Tuning.server.wolf_weight


func strength() -> float:
	return Tuning.server.wolf_strength


func race_label() -> String:
	return "늑대"


func body_radius() -> float:
	return HIT_RADIUS


func body_half_height() -> float:
	return BODY_RADIUS


func attack_def() -> SkillDef:
	return Skills.get_def("wolf_bite")


func base_colour() -> Color:
	return BASE_COLOUR


func is_dead() -> bool:
	return _dead


func corpse() -> WolfCorpse:
	if _corpse_name == "" or get_parent() == null:
		return null
	return get_parent().get_node_or_null(_corpse_name) as WolfCorpse


func _build_body() -> void:
	# On its side: the capsule's own axis is Y, turned onto Z.
	var lying := Basis(Vector3.RIGHT, PI * 0.5)
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = BODY_RADIUS
	shape.height = BODY_LENGTH
	collision.shape = shape
	collision.transform.basis = lying
	add_child(collision)

	var mesh_instance := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = BODY_RADIUS
	capsule.height = BODY_LENGTH
	mesh_instance.mesh = capsule
	mesh_instance.transform.basis = lying
	_material = StandardMaterial3D.new()
	_material.albedo_color = base_colour()
	mesh_instance.material_override = _material
	add_child(mesh_instance)

	# Which end is the head.
	var nose := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.22, 0.2, 0.3)
	nose.mesh = box
	nose.position = Vector3(0.0, 0.05, -BODY_LENGTH * 0.5)
	nose.material_override = _material
	add_child(nose)


func _refresh() -> void:
	super()
	if _label != null:
		_label.text = "늑대 %.0fkg\n%s" % [weight(), _label.text]


# ------------------------------------------------------------ the brain

func _think(delta: float) -> void:
	if _dying > 0:
		return
	if _pushed:
		# A push is the force door's; the legs wait until it has run out.
		if is_on_floor() and Vector2(velocity.x, velocity.z).length() <= PUSH_SETTLED:
			_pushed = false
		else:
			return
	if not is_on_floor():
		return
	match attack_phase:
		"windup", "recovery", "stunned":
			_stand()
			return
		"lunge":
			var def := attack_def()
			var speed := def.value("reach") / maxf(Tuning.server.wolf_lunge_time, 0.01)
			velocity.x = _bite_direction.x * speed
			velocity.z = _bite_direction.z * speed
			return
	_decide(delta)


func _decide(delta: float) -> void:
	var from_home := _flat(global_position - home).length()
	if mode == Mode.RETURN:
		if from_home <= HOME_RADIUS:
			mode = Mode.IDLE
			_wander_wait = Tuning.server.wolf_wander_pause
			_wander_left = 0.0
			_stand()
		else:
			_go(home, run_speed(), delta)
		return
	if mode == Mode.IDLE:
		var seen := _nearest_player(Tuning.server.wolf_aggro_range)
		if seen == null:
			_wander(delta)
			return
		_notice(seen.get_multiplayer_authority())
	# Chasing.
	var target := _living_player(target_peer)
	if target == null:
		target = _nearest_player(Tuning.server.wolf_aggro_range)
		if target != null:
			target_peer = target.get_multiplayer_authority()
	if target == null or from_home >= Tuning.server.wolf_leash_range:
		_give_up("leash" if target != null else "no_target")
		return
	var to_target := _flat(target.global_position - global_position)
	if to_target.length() <= Tuning.server.wolf_bite_start_range:
		_begin_bite(to_target)
	else:
		_go(target.global_position, run_speed(), delta)


func _notice(peer: int) -> void:
	target_peer = peer
	if mode != Mode.CHASE:
		mode = Mode.CHASE
		print("PLAYGROUND_WOLF_NOTICED wolf=%s target=%d" % [name, peer])


func _give_up(why: String) -> void:
	mode = Mode.RETURN
	target_peer = 0
	print("PLAYGROUND_WOLF_GAVE_UP wolf=%s why=%s" % [name, why])


func _wander(delta: float) -> void:
	if _wander_wait > 0.0:
		_wander_wait -= delta
		_stand()
		return
	if _wander_left <= 0.0:
		var angle := randf() * TAU
		var far := sqrt(randf()) * Tuning.server.wolf_wander_radius
		_wander_to = home + Vector3(cos(angle), 0.0, sin(angle)) * far
		_wander_left = WANDER_LEG_MAX
	_wander_left -= delta
	if _flat(_wander_to - global_position).length() <= WANDER_ARRIVE or _wander_left <= 0.0:
		_wander_left = 0.0
		_wander_wait = Tuning.server.wolf_wander_pause
		_stand()
		return
	_go(_wander_to, walk_speed(), delta)


func _go(to: Vector3, speed: float, delta: float) -> void:
	var heading := _flat(to - global_position)
	if heading.length_squared() < 0.0001:
		_stand()
		return
	heading = heading.normalized()
	velocity.x = heading.x * speed
	velocity.z = heading.z * speed
	rotation.y = lerp_angle(rotation.y, RangeShapes.yaw_for(heading), minf(1.0, TURN_RATE * delta))


func _stand() -> void:
	velocity.x = 0.0
	velocity.z = 0.0


func run_speed() -> float:
	return Player.human_walk_speed() * Tuning.server.wolf_run_speed_mult


func walk_speed() -> float:
	return Player.human_walk_speed() * Tuning.server.wolf_walk_speed_mult


static func _flat(vector: Vector3) -> Vector3:
	return Vector3(vector.x, 0.0, vector.z)


func _living_player(peer: int) -> Player:
	if peer == 0 or not is_instance_valid(Net.spawn_root):
		return null
	var player := Net.spawn_root.get_node_or_null(str(peer)) as Player
	if player == null or player.sync_dead or player.state == Player.State.DEAD:
		return null
	return player


func _nearest_player(within: float) -> Player:
	if not is_instance_valid(Net.spawn_root):
		return null
	var best: Player = null
	var best_distance := within
	for child in Net.spawn_root.get_children():
		var player := child as Player
		if player == null or player.sync_dead or player.state == Player.State.DEAD:
			continue
		var distance := _flat(player.global_position - global_position).length()
		if distance <= best_distance:
			best = player
			best_distance = distance
	return best


# ------------------------------------------------------------ the bite

# Stops, turns to where the target stands now, and books the strike with the
# judge: the path (wolf_bite_range long, wolf_bite_width across) is ruled at
# the end of the windup, and the telegraph on every screen is that path.
func _begin_bite(to_target: Vector3) -> void:
	var def := attack_def()
	var judge := ServerAuthority.instance
	if def == null or judge == null:
		return
	_bite_direction = to_target.normalized() if to_target.length_squared() > 0.0001 else attack_direction()
	rotation.y = RangeShapes.yaw_for(_bite_direction)
	_stand()
	_phase_left = def.impact_time()
	_set_attack_phase("windup")
	judge.schedule_strike(self, def, _bite_direction)
	attacks_made += 1
	bites_started += 1
	print("PLAYGROUND_WOLF_BITE wolf=%s target=%d direction=(%.2f, %.2f)" % [
		name, target_peer, _bite_direction.x, _bite_direction.z])


# The bite's clock. The scarecrow's pattern runs on a timer; this one is
# started by the brain and only counted here.
func _attack_step(delta: float) -> void:
	if _dying > 0:
		return
	var def := attack_def()
	if def == null:
		return
	match attack_phase:
		"windup":
			_phase_left -= delta
			# The leap starts once the judge has ruled the path, so the body
			# is ruled from where it wound up. The margin is for a booking
			# that is gone without having been ruled.
			var judge := ServerAuthority.instance
			var booked := judge != null and not judge.pending_strike(self).is_empty()
			if _phase_left <= 0.0 and (not booked or _phase_left < -0.1):
				_phase_left = Tuning.server.wolf_lunge_time
				_set_attack_phase("lunge")
		"lunge":
			_phase_left -= delta
			if _phase_left <= 0.0:
				_stand()
				_phase_left = def.value("recovery")
				_set_attack_phase("recovery")
		"recovery", "stunned":
			_phase_left -= delta
			if _phase_left <= 0.0:
				_set_attack_phase("")


func _cancel_bite(why: String) -> void:
	if attack_phase != "windup" and attack_phase != "lunge":
		return
	if ServerAuthority.instance != null:
		ServerAuthority.instance.cancel_strike(self, why)
	_phase_left = 0.0
	_set_attack_phase("")


# ------------------------------------------------------------ being hit

func apply_force_event(event: Dictionary) -> void:
	if not is_multiplayer_authority() or _dead:
		return
	super(event)
	if Vector2(velocity.x, velocity.z).length() > PUSH_SETTLED or velocity.y > 0.0 or not is_on_floor():
		_pushed = true
	# Thrown off its feet: there is no leap from the air. A push it held
	# against (a slide) leaves the bite alone.
	if bool(event.get("knock_launched", true)):
		_cancel_bite("launched")
	# Whoever hit it last is who it is after. Not while it is walking home.
	var source := int(event.get("source_peer", 0))
	if source > 0 and mode != Mode.RETURN and _dying == 0 and _living_player(source) != null:
		_notice(source)


func take_damage(amount: float, hit_id: int) -> void:
	if _dead or _dying > 0:
		return
	super(amount, hit_id)
	if is_multiplayer_authority() and hp <= 0.0:
		_dying = DEATH_STEPS
		_cancel_bite("dead")


func set_hold_display(peer: int) -> void:
	super(peer)
	if is_multiplayer_authority() and peer != 0:
		# Picked up: the judge has dropped the booking; the phase goes with it.
		_cancel_bite("held")


# ------------------------------------------------------------ dying

func _physics_process(delta: float) -> void:
	if _dead:
		if is_multiplayer_authority():
			_dead_step(delta)
		return
	super(delta)
	if is_multiplayer_authority() and _dying > 0:
		_dying -= 1
		if _dying == 0:
			_die()


func _die() -> void:
	var judge := ServerAuthority.instance
	if judge != null:
		judge.cancel_strike(self, "dead")
		judge.drop_hold_of(self, "target_dead")
	var at := global_position
	var yaw := rotation.y
	var carried := velocity
	deaths += 1
	_set_attack_phase("dead")
	_corpse_name = "%s_corpse_%d" % [name, corpses_made]
	corpses_made += 1
	_corpse_left = Tuning.server.wolf_corpse_time
	var body := _make_corpse(_corpse_name, at, yaw)
	# The carcass leaves with the speed the killing blow gave the body, and it
	# is given that speed by the one force door like any other body.
	if body != null and judge != null and carried.length() > PUSH_SETTLED:
		judge.send_force(body, ForceSystem.make_event(
			ForceSystem.Kind.KNOCKBACK, carried, carried.length(), 0.0, 0, false))
	if multiplayer.has_multiplayer_peer():
		show_corpse.rpc(_corpse_name, at, yaw)
	_state_left = 0.0
	print("PLAYGROUND_WOLF_DIED wolf=%s at=(%.2f, %.2f, %.2f) corpse=%s" % [name, at.x, at.y, at.z, _corpse_name])


# The dead body's part on the server: the phase keeps going out, slowly, so
# a peer that joins late (or dropped the last packet) hides its copy; and the
# carcass's clock.
func _dead_step(delta: float) -> void:
	_state_left -= delta
	if _state_left <= 0.0 and multiplayer.has_multiplayer_peer():
		_state_left = ServerAuthority.VIEW_HEARTBEAT
		push_state.rpc(global_position, 0.0, "dead", hit_ids, hit_damages, rotation.y)
	if _corpse_name == "":
		return
	_corpse_left -= delta
	if _corpse_left <= 0.0:
		var gone := _corpse_name
		_corpse_name = ""
		_remove_corpse(gone)
		if multiplayer.has_multiplayer_peer():
			hide_corpse.rpc(gone)
		print("PLAYGROUND_WOLF_CORPSE_GONE wolf=%s corpse=%s" % [name, gone])


# The phase is how every screen learns it is dead (Dummy.push_state).
func _set_attack_phase(phase: String) -> void:
	super(phase)
	_show_dead(phase == "dead")


func _show_dead(dead: bool) -> void:
	if dead == _dead:
		return
	_dead = dead
	visible = not dead
	collision_layer = 0 if dead else LAYER
	collision_mask = 0 if dead else Layers.SOLID_DUMMY
	velocity = Vector3.ZERO
	if dead:
		remove_from_group(ServerAuthority.HOLDABLE_GROUP)
	else:
		add_to_group(ServerAuthority.HOLDABLE_GROUP)


# Code-built nodes do not replicate (CLAUDE.md 1): each peer builds its own
# carcass under the same parent with the same name, and its position then
# rides Rock.push_state like a rock's.
func _make_corpse(corpse_name: String, at: Vector3, yaw: float) -> WolfCorpse:
	var parent := get_parent()
	if parent == null:
		return null
	_remove_corpse(corpse_name)
	var body := WolfCorpse.new()
	var parent_3d := parent as Node3D
	body.setup(corpse_name, parent_3d.to_local(at) if parent_3d != null else at, Tuning.server.wolf_weight)
	body.rotation.y = yaw
	parent.add_child(body)
	return body


func _remove_corpse(corpse_name: String) -> void:
	var node := get_parent().get_node_or_null(corpse_name) if get_parent() != null else null
	if node != null:
		node.name = corpse_name + "_gone"
		node.queue_free()


@rpc("authority", "call_remote", "reliable")
func show_corpse(corpse_name: String, at: Vector3, yaw: float) -> void:
	if not at.is_finite() or not corpse_name.is_valid_filename():
		return
	_corpse_name = corpse_name
	_make_corpse(corpse_name, at, yaw)


@rpc("authority", "call_remote", "reliable")
func hide_corpse(corpse_name: String) -> void:
	if _corpse_name == corpse_name:
		_corpse_name = ""
	_remove_corpse(corpse_name)


# For the automated checks only (host): the wolf put at `at` as if it had
# always lived there -- alive, full, idle, with nothing booked.
func harness_place(at: Vector3) -> void:
	if not is_multiplayer_authority():
		return
	if ServerAuthority.instance != null:
		ServerAuthority.instance.cancel_strike(self, "harness")
	_dying = 0
	_phase_left = 0.0
	_set_attack_phase("")
	home = at
	global_position = at
	sync_position = at
	velocity = Vector3.ZERO
	_blind_left = SyncRules.TELEPORT_BLIND
	collision_layer = 0
	hp = max_hp()
	mode = Mode.IDLE
	target_peer = 0
	_pushed = false
	_wander_left = 0.0
	_wander_wait = Tuning.server.wolf_wander_pause
	_refresh()
