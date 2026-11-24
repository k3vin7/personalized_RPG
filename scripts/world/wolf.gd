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
#   return  wolf_leash_range from its mark (and its target past it too) it
#           goes home, faster than it runs, and is full again when it arrives.
#           On the way a blow turns it only if the hitter stands inside the
#           leash of its mark.
#
# 늑대 b: the chase and the way home follow the navigation mesh the players'
# own move orders use (the world's one baked map); the leap is a straight
# line. Wolves under one parent node are a pack: what one notices, or is hit
# by, all of them chase. A dead wolf is back on its mark, full, after
# wolf_respawn_time.
#
# A blow in the windup breaks the bite: any force event whose power is at
# least wolf_interrupt_power (0: every blow -- an early monster) ends it, the
# judge drops the booked strike, and the wolf stands for wolf_interrupt_pause
# before it tries again. The leap itself cannot be broken that way. A push
# past its tolerance throws it at any time, and a body in the air has nothing
# to leap from, so that ends the bite too.
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
# 2026-11-23: its size is the server's data now (Tuning.server.wolf_body_radius,
# _body_length, _hit_radius), read through radius() / length() below.
# The radius the wolves standing in the maps were put down for: a bigger body
# is lifted by the difference when it enters the world, so its belly is where
# the old one's was and not in the ground.
const PLACED_RADIUS := 0.35
# The nose box, for a body of PLACED_RADIUS; it grows with the body.
const NOSE_SIZE := Vector3(0.22, 0.2, 0.3)
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
# The path is asked for again this often, or at once when its goal has moved
# this far; a point of it this near is behind the body.
const REPATH_SECONDS := 0.3
const REPATH_MOVED := 1.0
const PATH_POINT_REACHED := 0.4
# The eye line to the target, off the ground by this much.
const SIGHT_LIFT := 0.3

var mode := Mode.IDLE
# Who it is after: the peer it noticed, replaced by whoever hits it.
var target_peer := 0
var bites_started := 0
var shakes_started := 0
var bites_interrupted := 0
var corpses_made := 0
var deaths := 0
var respawns := 0
# How many path answers had more than a straight line in them (the checks).
var detours := 0

var _bite_direction := Vector3.FORWARD
var _pushed := false
var _wander_to := Vector3.ZERO
var _wander_wait := 0.0
var _wander_left := 0.0
var _dying := 0
var _dead := false
var _corpse_name := ""
var _corpse_left := 0.0
var _respawn_left := 0.0
var _path := PackedVector3Array()
var _path_index := 0
var _path_goal := Vector3.INF
var _path_age := 0.0


func max_hp() -> float:
	return Tuning.server.wolf_max_hp


func weight() -> float:
	return Tuning.server.wolf_weight


func strength() -> float:
	return Tuning.server.wolf_strength


func race_label() -> String:
	return "늑대"


func species() -> String:
	return "wolf"


# The capsule's radius and its length, nose to tail (the species' data).
static func radius() -> float:
	return float(Tuning.server.wolf_body_radius)


static func length() -> float:
	return float(Tuning.server.wolf_body_length)


func body_radius() -> float:
	return float(Tuning.server.wolf_hit_radius)


func body_half_height() -> float:
	return radius()


# How far above or below the top of the back a rider's feet may be: the back
# is round, so feet off its middle line stand lower.
const BACK_FEET_BELOW := 0.45
const BACK_FEET_ABOVE := 0.35


func rideable() -> bool:
	# 2026-11-24: behind the hold on riding (PhysicsTuning.back_ride_enabled).
	return bool(Tuning.server.back_ride_enabled) and bool(Tuning.server.wolf_rideable) and not _dead and _dying <= 0


# The back is the top of the lying capsule: as long as the body, as wide as
# it, in the body's own frame (so it turns with the wolf).
func back_holds(feet: Vector3, reach: float) -> bool:
	var local := to_local(feet)
	var over := local.y - radius()
	if over < -BACK_FEET_BELOW or over > BACK_FEET_ABOVE:
		return false
	return absf(local.z) <= length() * 0.5 + reach * 0.5 and absf(local.x) <= radius() + reach * 0.5


func _ready() -> void:
	# Before the scarecrow's _ready takes this place as its mark.
	position.y += maxf(0.0, radius() - PLACED_RADIUS)
	super()


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
	shape.radius = radius()
	shape.height = length()
	collision.shape = shape
	collision.transform.basis = lying
	add_child(collision)

	var mesh_instance := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = radius()
	capsule.height = length()
	mesh_instance.mesh = capsule
	mesh_instance.transform.basis = lying
	_material = StandardMaterial3D.new()
	_material.albedo_color = base_colour()
	mesh_instance.material_override = _material
	add_child(mesh_instance)
	_body_mesh = mesh_instance

	# Which end is the head.
	var nose := MeshInstance3D.new()
	var box := BoxMesh.new()
	var grown := radius() / PLACED_RADIUS
	box.size = NOSE_SIZE * grown
	nose.mesh = box
	nose.position = Vector3(0.0, 0.05 * grown, -length() * 0.5)
	nose.material_override = _material
	add_child(nose)
	_nose_mesh = nose
	_nose_at = nose.position


# The shake-off's windup on every screen (the phase is pushed with the rest
# of the scarecrow's state): the body sways from side to side. The picture
# only -- the collider stays where it is.
const SHAKE_SWAY := 0.12
const SHAKE_RATE := 38.0
var _body_mesh: MeshInstance3D
var _nose_mesh: MeshInstance3D
var _nose_at := Vector3.ZERO


func _process(delta: float) -> void:
	super(delta)
	if _body_mesh == null:
		return
	var sway := sin(float(Time.get_ticks_msec()) / 1000.0 * SHAKE_RATE) * SHAKE_SWAY if attack_phase == "shake" else 0.0
	_body_mesh.position.x = sway
	if _nose_mesh != null:
		_nose_mesh.position.x = sway


func _refresh() -> void:
	super()
	if _label != null:
		_label.text = "늑대 %.0fkg\n%s" % [weight(), _label.text]


# 2026-11-23: the flinch's picture: the body squashes down and jerks back
# (its tail end, +Z) and comes back. The capsule lies on its side, so its
# own Z is the world's up.
func _draw_flinch(amount: float) -> void:
	if _body_mesh == null:
		return
	var squash := Tuning.values.flinch_squash * amount
	_body_mesh.scale = Vector3(1.0 + squash * 0.5, 1.0, 1.0 - squash)
	var back := Tuning.values.flinch_recoil * amount
	_body_mesh.position.z = back
	if _nose_mesh != null:
		_nose_mesh.position.z = _nose_at.z + back
		_nose_mesh.position.y = _nose_at.y - squash * radius()


# The leap cannot be broken by a blow (see the top), nor a body that is going.
func can_flinch() -> bool:
	return super() and not _dead and _dying == 0 and attack_phase != "lunge"


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
		"windup", "recovery", "stunned", "shake":
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
			# Home: whatever was done to it on the way out is undone.
			if hp < max_hp():
				hp = max_hp()
				_refresh()
			print("PLAYGROUND_WOLF_HOME wolf=%s hp=%.0f" % [name, hp])
		else:
			_go_path(home, run_speed() * Tuning.server.wolf_return_speed_mult, delta)
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
	if target == null:
		_give_up("no_target")
		return
	# Past the leash, after a body that is past it too. (A body inside it is
	# toward home from here, which is where a blow on the way back sends it.)
	if from_home >= Tuning.server.wolf_leash_range and not _inside_leash(target):
		_give_up("leash")
		return
	var to_target := _flat(target.global_position - global_position)
	if to_target.length() <= Tuning.server.wolf_bite_start_range and _sees(target):
		_begin_bite(to_target)
	else:
		_go_path(target.global_position, run_speed(), delta)


# Its own senses, or a blow: it is after `peer`, and so is its pack.
func _notice(peer: int) -> void:
	_set_target(peer)
	for mate in pack():
		mate.alerted(peer)


# A pack mate noticed `peer` or was hit by it. One walking home answers the
# way it answers a blow of its own.
func alerted(peer: int) -> void:
	if _dead or _dying > 0 or not is_multiplayer_authority():
		return
	var player := _living_player(peer)
	if player == null or (mode == Mode.RETURN and not _inside_leash(player)):
		return
	_set_target(peer)


func _set_target(peer: int) -> void:
	target_peer = peer
	if mode != Mode.CHASE:
		mode = Mode.CHASE
		print("PLAYGROUND_WOLF_NOTICED wolf=%s target=%d" % [name, peer])


# The pack: the other wolves under the same parent node.
func pack() -> Array[Wolf]:
	var out: Array[Wolf] = []
	if get_parent() == null:
		return out
	for child in get_parent().get_children():
		var mate := child as Wolf
		if mate != null and mate != self:
			out.append(mate)
	return out


func _inside_leash(player: Player) -> bool:
	return _flat(player.global_position - home).length() <= Tuning.server.wolf_leash_range


# Nothing solid between it and the target: a bite does not start through a
# wall or a stand of trees, however near the body on the other side is.
func _sees(target: Player) -> bool:
	var query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * SIGHT_LIFT, target.global_position, Layers.TERRAIN)
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()


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


# Toward `to` along the navigation mesh -- the one the world baked, which is
# the one a player's move order is answered from. Where there is no mesh (or
# no answer) it goes straight.
func _go_path(to: Vector3, speed: float, delta: float) -> void:
	_path_age += delta
	if _path_goal == Vector3.INF or _path_age >= REPATH_SECONDS or _flat(to - _path_goal).length() > REPATH_MOVED:
		_path_goal = to
		_path_age = 0.0
		_path_index = 0
		_path = PackedVector3Array()
		var map := get_world_3d().navigation_map
		# A map that has not been built yet answers with an error, not a path.
		if NavigationServer3D.map_get_iteration_id(map) > 0:
			_path = NavigationServer3D.map_get_path(map, global_position, to, true)
			if _path.size() > 2:
				detours += 1
	while _path_index < _path.size() - 1 \
			and _flat(_path[_path_index] - global_position).length() <= PATH_POINT_REACHED:
		_path_index += 1
	_go(_path[_path_index] if not _path.is_empty() else to, speed, delta)


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
	# 2026-11-23: it does not bite at a body on its own back (the bite would
	# pass it by): it stands, and shakes when wolf_shake_after is up.
	if target_peer != 0 and judge.rider_mount(target_peer) == self:
		_stand()
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
	# 2026-11-23: someone has been on its back long enough: it shakes.
	if (attack_phase == "" or attack_phase == "recovery" or attack_phase == "stunned") and _wants_shake():
		_stand()
		_phase_left = Tuning.server.wolf_shake_windup
		shakes_started += 1
		_set_attack_phase("shake")
		print("PLAYGROUND_WOLF_SHAKE wolf=%s windup=%.2f" % [name, _phase_left])
	match attack_phase:
		"shake":
			_phase_left -= delta
			if _phase_left <= 0.0:
				if ServerAuthority.instance != null:
					ServerAuthority.instance.shake_riders_off(self, Tuning.server.wolf_shake_power, Tuning.server.wolf_shake_angle)
				_phase_left = Tuning.server.wolf_shake_recovery
				_set_attack_phase("recovery")
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


# Whether anyone has been on this back for wolf_shake_after (the server's
# rider table).
func _wants_shake() -> bool:
	var judge := ServerAuthority.instance
	if judge == null or not rideable():
		return false
	for rider in judge.riders_of(self):
		if judge.rider_seconds(rider.get_multiplayer_authority()) >= Tuning.server.wolf_shake_after:
			return true
	return false


func _cancel_bite(why: String) -> void:
	if attack_phase != "windup" and attack_phase != "lunge":
		return
	if ServerAuthority.instance != null:
		ServerAuthority.instance.cancel_strike(self, why)
	_phase_left = 0.0
	_set_attack_phase("")


# Broken in the windup by a blow it held against: the booked strike is gone
# and the wolf stands, shown as stunned on every screen, before it may wind
# up again.
func _interrupt_bite() -> void:
	if ServerAuthority.instance != null:
		ServerAuthority.instance.cancel_strike(self, "interrupted")
	bites_interrupted += 1
	_stand()
	_phase_left = Tuning.server.wolf_interrupt_pause
	_set_attack_phase("stunned")
	print("PLAYGROUND_WOLF_INTERRUPTED wolf=%s pause=%.2f" % [name, _phase_left])


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
	elif attack_phase == "windup" and float(event.get("base_power", 0.0)) >= Tuning.server.wolf_interrupt_power:
		_interrupt_bite()
	# Whoever hit it last is who it is after, and its pack's. On the way home
	# only a hitter inside the leash of its mark turns it round.
	var source := int(event.get("source_peer", 0))
	var hitter := _living_player(source) if source > 0 and _dying == 0 else null
	if hitter != null and (mode != Mode.RETURN or _inside_leash(hitter)):
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
	if is_multiplayer_authority():
		_corpse_step(delta)
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
	_respawn_left = Tuning.server.wolf_respawn_time
	_retire_corpse()
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
# clock that puts it back on its mark.
func _dead_step(delta: float) -> void:
	_state_left -= delta
	if _state_left <= 0.0 and multiplayer.has_multiplayer_peer():
		_state_left = ServerAuthority.VIEW_HEARTBEAT
		push_state.rpc(global_position, 0.0, "dead", hit_ids, hit_damages, rotation.y, flinches)
	_respawn_left -= delta
	if _respawn_left <= 0.0:
		_respawn()


# Back on its mark as if it had always been there. The phase leaving "dead"
# is what shows it again on every screen; the mark is where the next state
# packet puts it.
func _respawn() -> void:
	respawns += 1
	global_position = home
	sync_position = home
	velocity = Vector3.ZERO
	hp = max_hp()
	mode = Mode.IDLE
	target_peer = 0
	_pushed = false
	_path_goal = Vector3.INF
	_wander_left = 0.0
	_wander_wait = Tuning.server.wolf_wander_pause
	_phase_left = 0.0
	_set_attack_phase("")
	# Blind for a moment, like every placed body (CLAUDE.md 9).
	_blind_left = SyncRules.TELEPORT_BLIND
	collision_layer = 0
	_state_left = 0.0
	_refresh()
	print("PLAYGROUND_WOLF_RESPAWNED wolf=%s at=(%.2f, %.2f, %.2f)" % [name, home.x, home.y, home.z])


# The carcass's clock, alive or dead (it can outlast the respawn).
func _corpse_step(delta: float) -> void:
	if _corpse_name == "":
		return
	_corpse_left -= delta
	if _corpse_left <= 0.0:
		_retire_corpse()


func _retire_corpse() -> void:
	if _corpse_name == "":
		return
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
	var body := WolfCorpse.new()
	var parent_3d := parent as Node3D
	body.setup(corpse_name, parent_3d.to_local(at) if parent_3d != null else at, Tuning.server.wolf_weight)
	body.rotation.y = yaw
	parent.add_child(body)
	return body


# Gone from the game at once, and from the tree a little later: see
# WolfCorpse.retire() for why the node outlives the carcass.
func _remove_corpse(corpse_name: String) -> void:
	var node := get_parent().get_node_or_null(corpse_name) as WolfCorpse if get_parent() != null else null
	if node != null:
		node.retire()


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
	_path_goal = Vector3.INF
	_wander_left = 0.0
	_wander_wait = Tuning.server.wolf_wander_pause
	_refresh()
