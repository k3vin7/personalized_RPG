class_name Player
extends CharacterBody3D

# State, identity and replication. The movement, climbing and grabbing scripts
# hang off this one and go through change_state() rather than setting state
# themselves, so there is a single place that says what the character is doing.

enum State {
	IDLE,
	MOVE,
	AIRBORNE,
	DASH,
	CLIMB,
	MANTLE,
	GRABBING,
	GRABBED,
	STUNNED,
	# M-1: a cast's windup and recovery. Both lock out moving, jumping, dashing
	# and other casts; the body stands where it is.
	CASTING,
	RECOVERING,
	# M-2: knocked down. Lying for down_time, then getup_time standing up.
	DOWNED,
	DEAD,
}

# Names kept for the call sites; the numbers live in Layers and nowhere else.
const WORLD_LAYER := Layers.WORLD
const WALL_LAYER := Layers.WALL
const CLIMBABLE_LAYER := Layers.CLIMBABLE
const PLAYER_LAYER := Layers.PLAYER
const THROWABLE_LAYER := Layers.THROWABLE

# M-4: the human's body, at 180 cm. Every other race's capsule is this scaled
# by its height (RaceData.height_cm / the human's), so these two are the
# reference and nothing reads them for a particular body any more: radius()
# and half_height() below do, and resize the capsule when the race changes.
const BODY_RADIUS := 0.4
const BODY_HALF_HEIGHT := 0.9
# DOC: a held rock or team mate sits 0.8 m above the head, where it is visible
# on both screens and clear of the holder's own body.
const HAND_HEIGHT := 0.8
# A replicated step bigger than this is a teleport, not travel: a respawn, a
# test placement, or a large correction.
# The blob under the feet is drawn on its own layer, like the aim rings, so a
# camera or a capture can leave the markers out without touching the bodies.
const SHADOW_LAYER := 1 << 17
# How far down to look for a floor to put the blob on.
const SHADOW_REACH := 40.0
# How small the blob gets when the body is high up, and the height at which it
# has shrunk all the way: further off the ground is smaller and fainter, which
# is the other half of reading height off it.
const SHADOW_MIN_SCALE := 0.45
const SHADOW_FADE_HEIGHT := 4.0

# N-2: how many times the server has put this body back. Read by the checks.
var corrections_received := 0
# N-4: how many respawns this body has applied. The checks wait on it: a
# client's respawn lands a round trip after it was asked for.
var respawns_applied := 0
# N-3: where the server last put this body while it was being carried. Every
# peer applies it, the owner included -- a carried body writes no position of
# its own -- the way a rock in a hand is shown where the server says it is.
var _held_position := Vector3.INF
var _has_held_position := false
# N-3: the holder this body does not collide with while carried. A capsule put
# in a hand overlaps the head under it, and the solver answered by shoving the
# holder along -- measured as a holder drifting twenty metres while standing
# still. Rocks and scarecrows have had this exception since stage E.
var _excepted_holder: Node3D = null

# Stand-in for animation: the state is readable off the body on both screens.
const STATE_COLORS := {
	State.IDLE: "6fa8dc",
	State.MOVE: "6fa8dc",
	State.AIRBORNE: "9fd3ff",
	State.DASH: "ffd166",
	State.CLIMB: "8ef5a8",
	State.MANTLE: "8ef5a8",
	State.GRABBING: "ffa94d",
	State.GRABBED: "ff7b6b",
	State.STUNNED: "ff7b6b",
	State.CASTING: "f4e285",
	State.RECOVERING: "c9b26b",
	State.DOWNED: "b07a7a",
	State.DEAD: "4b535c",
}

signal state_changed(new_state: int)

var stats: CharacterStats
var state: int = State.IDLE
var hp: float = 100.0

# Written by the authority, read by everyone else.
var sync_position := Vector3.ZERO
var sync_yaw := 0.0
var sync_state: int = State.IDLE

# Replicated by the Vitals synchronizer, alongside hp, rather than by the pose
# one. It says the same thing as sync_state == DEAD today; in B-d it becomes
# the server's word on it and sync_state keeps only the pose.
var sync_dead := false

# Stage E follow-up: whether this body is in the air because it jumped, or
# because it came off something. The hold table needs to tell those apart --
# a jump keeps what you are carrying, a fall does not -- and only the owner
# knows which it was, so it travels with the pose.
var sync_jumped := false
# M-5: the weapon is the server's (Vitals synchronizer, with the race). The
# owner asks (Intent.WEAPON); the server writes it; every peer, the owner too,
# applies what arrives. Nothing on a client writes this and keeps it.
var sync_weapon: int = WeaponKinds.Kind.NONE
# M-5: the cast's show, replicated so the other screen can read a windup: the
# slot's skill, the phase, and the owner's wall clock when it started. Remote
# bodies replay the same hooks off these.
var sync_skill_id := ""
var sync_skill_phase := ""
var sync_skill_at := 0.0
var _shown_skill_stamp := ""
# For the checks: how long after the owner's clock the phase was seen here.
var last_remote_phase_delay := -1.0
var remote_phases_seen := 0

# H-1: the stats travel on the Vitals synchronizer, which is the server's, not
# on the pose one, which is the owner's. A shove is worked out from the pusher's
# strength against the target's weight, so every peer needs the target's
# numbers -- but a client stating its own was a client telling the server what
# to judge it by. What crosses now is the race id and whatever the debug
# sliders are holding it off; the abilities themselves come out of the race
# resource, which every peer already has.
var sync_race: int = Races.DEFAULT
var sync_strength_override := NAN
var sync_weight_override := NAN
var sync_gear_weight := 0.0

var movement: PlayerMovement
var climb: PlayerClimb
var grab: PlayerGrab
# M-1: the eight slots and the cast flow. Local, like the three above.
var skills: PlayerSkills
# M-1: the procedural show of a cast -- a lean, and a box that is the strike.
var _skill_lean_deg := 0.0
var _strike_box: MeshInstance3D
var _strike_left := 0.0
# M-4: the race the capsule is currently sized for, and the pieces resized.
var _body_race := -1
var _body_shape: CapsuleShape3D
var _body_mesh: CapsuleMesh
var _facing: MeshInstance3D
var stamina := 100.0
# H-3: the owner's stamina, replicated on the pose synchronizer for display on
# other screens. Spending it is still the owner's (the server does not check
# stamina costs yet -- that is the combat stage), so this is a readout, not a
# ruling: nothing on another peer may branch on it.
var sync_stamina := 100.0
var camera: QuarterCamera

var _visual: Node3D
var _shadow: MeshInstance3D
# The camera, the HUD bars and the debug panel: ours to free when we go.
var _owned_views: Array[Node] = []
var _material: StandardMaterial3D
var _label: Label3D
var _default_snap := 0.3
var spawn_point := Vector3.ZERO
var _stun_left := 0.0
# M-2: how long the body still lies, then how long standing up still takes. No
# input through either; the pose eases from lying to standing through the
# second. Read by the checks.
var _down_left := 0.0
var _getup_left := 0.0
var downs_applied := 0
# Fall measurement. The peak is tracked rather than the launch height: a push
# that throws you up and then down has to count the whole drop.
var _fall_peak_y := 0.0
var _fall_tracking := false
var last_fall_height := 0.0
var weapon: int = WeaponKinds.Kind.NONE
var _weapon_node: Node3D
# A short line under the name: escape progress, and anything else worth reading
# off the body.
var overhead_note := ""
# v4 H-2: the knockback readout, replicated so it shows on every screen and not
# only on the machine that was pushed.
var sync_knock := ""
var _knock_left := 0.0
# Long enough to read after a shove lands, short enough that it is gone before
# the next one.
const KNOCK_SHOW_TIME := 2.0
# B-c: a read-only copy of a row in ServerAuthority's hold table, written by
# set_hold_display() on every peer and decided nowhere else.
var holder_peer := 0
# Stage C, the felt delay. A press shows on this body at once -- a lean and a
# brighter skin -- while the ruling is still crossing the network. It is only a
# picture: nothing about the hit, the hold or the damage is decided here, and a
# refusal from the server takes the picture back.
var predicted_action := -1
var predicted_at_msec := 0
var _predicted_left := 0.0
var _teleport_blind_left := 0.0
var _respawning := false
# See _physics_process: how long a stale "you are dead" copy is ignored after
# the server has told this body to come back.
const RESPAWN_ECHO_GRACE := 0.5
var _respawn_echo_left := 0.0
var _jumped_this_flight := false


# B-d threw this switch. HP and the alive flag are written by the server and
# replicated out by the Vitals synchronizer; the pose stays on the other
# synchronizer and stays the owner's. Nothing here writes hp any more: damage,
# death, the fall and the way back are all rulings, and this file applies them.
const VITALS_OWNED_BY_SERVER := true


func _enter_tree() -> void:
	# The node is named after the peer, so every peer works out the authority
	# for itself with no extra message.
	# Recursive by default, which is the point: the MultiplayerSynchronizer is
	# already in the scene as a child, and a synchronizer created in code during
	# spawn processing never gets a network id at all.
	set_multiplayer_authority(name.to_int())
	# Pose and vitals are replicated by two separate synchronizers so the two
	# can have different owners. Today both belong to the owning client, which
	# is the behaviour B-b keeps; the seam is what B-b adds.
	var vitals := get_node_or_null("Vitals")
	if vitals != null:
		vitals.set_multiplayer_authority(1 if VITALS_OWNED_BY_SERVER else name.to_int())


# Who may write HP and the alive flag. One place to read, so no caller has to
# know which stage we are in.
func vitals_authority() -> int:
	return 1 if VITALS_OWNED_BY_SERVER else get_multiplayer_authority()


func vitals_are_mine() -> bool:
	return vitals_authority() == multiplayer.get_unique_id() or not multiplayer.has_multiplayer_peer()


func _ready() -> void:
	stats = (load("res://data/default_stats.tres") as CharacterStats).duplicate(true)
	hp = stats.max_hp
	stamina = stats.max_stamina
	sync_stamina = stamina
	collision_layer = PLAYER_LAYER
	# Rocks are included: a rock you can walk through is not a thing you would
	# bother picking up, and a thrown one has to be able to knock you about.
	collision_mask = Layers.SOLID_PLAYER
	floor_snap_length = _default_snap
	# Stage D: leaving a moving surface carries its speed with you. This is the
	# engine's own platform handling rather than something hand-rolled, and a
	# player's head is a platform like any other because the layer mask it
	# watches is every layer.
	platform_on_leave = CharacterBody3D.PLATFORM_ON_LEAVE_ADD_VELOCITY
	add_to_group(ServerAuthority.HOLDABLE_GROUP)
	_build_body()
	sync_position = global_position
	spawn_point = global_position

	if is_local():
		movement = PlayerMovement.new()
		movement.name = "PlayerMovement"
		add_child(movement)
		movement.setup(self)

		climb = PlayerClimb.new()
		climb.name = "PlayerClimb"
		add_child(climb)
		climb.setup(self)

		grab = PlayerGrab.new()
		grab.name = "PlayerGrab"
		add_child(grab)
		grab.setup(self)

		skills = PlayerSkills.new()
		skills.name = "PlayerSkills"
		add_child(skills)
		skills.setup(self)

		camera = QuarterCamera.new()
		camera.name = "QuarterCamera"
		# Not under the player's parent: that node is the spawner's spawn path,
		# and anything living there is treated as a replicated player.
		get_tree().current_scene.add_child(camera)
		camera.set_target(self)

		var fader := OcclusionFader.new()
		fader.name = "OcclusionFader"
		camera.add_child(fader)
		fader.setup(camera, self)

		var bars := StatusBars.new()
		bars.name = "StatusBars"
		get_tree().current_scene.add_child(bars)
		bars.setup(self)

		var panel := DebugPanel.new()
		panel.name = "DebugPanel"
		get_tree().current_scene.add_child(panel)
		panel.setup(self)

		# The camera, the bars and the panel hang off the scene rather than off
		# this body, because the body's parent is the spawner's path and
		# anything living there is treated as a replicated player. Nothing else
		# owns them, so this body does: without it, a local player that is
		# despawned (quit, or a disconnect) leaves three nodes behind that go on
		# reading a freed body for a frame, which is where the shutdown's
		# "!is_inside_tree()" errors came from.
		_owned_views.assign([camera, bars, panel])
		tree_exiting.connect(_free_views)
	set_physics_process(true)


# Anything the local view builds and nobody else owns. The body owns their
# lifetime, because its parent is the spawner's path and a despawn would
# otherwise leave them reading a freed body.
func add_owned_view(node: Node) -> void:
	_owned_views.append(node)


func _free_views() -> void:
	for node in _owned_views:
		if is_instance_valid(node):
			# Queued, not freed on the spot: this runs while the tree is pulling
			# itself apart, and taking a node out from under that loop is how a
			# tidy up turns into a crash.
			node.queue_free()
	_owned_views.clear()


func is_local() -> bool:
	return is_multiplayer_authority()


func change_state(new_state: int) -> void:
	if state == new_state:
		return
	if is_local() and state == State.DEAD and not _respawning:
		return
	var previous := state
	state = new_state
	_update_fall_tracking(previous, new_state)
	if state != new_state:
		return # A nested change (a landing, a hold) got there first.
	_update_hold(previous, new_state)
	# M-1: leaving a cast by any route but its own end (a stun, a grab, a fall,
	# a death) takes the picture of it down with it.
	if skills != null and (previous == State.CASTING or previous == State.RECOVERING) \
			and new_state != State.CASTING and new_state != State.RECOVERING and new_state != State.IDLE:
		skills.on_interrupted()
	if previous == State.DOWNED and new_state != State.DOWNED:
		_down_left = 0.0
		_getup_left = 0.0
	_apply_predicted_pose()
	_apply_state_colour()
	state_changed.emit(new_state)


# 7-6 used to be enforced here, by each machine watching its own state: a
# holder that stopped being GRABBING dropped what it held. B-c moved the ruling
# to the hold table, which sees the stun, the throw, the death and the fall as
# one case, so all that is left here is tidying the local display.
func _update_hold(previous: int, new_state: int) -> void:
	if grab == null:
		return
	if previous == State.GRABBED and new_state != State.GRABBED:
		grab.clear_holder()


# Every way of leaving the air passes through here, so there is one place that
# decides whether a drop ended in a landing or in something else.
func _update_fall_tracking(previous: int, new_state: int) -> void:
	if new_state == State.AIRBORNE:
		if not _fall_tracking:
			_fall_tracking = true
			_fall_peak_y = global_position.y
		return
	if not _fall_tracking:
		return
	_fall_tracking = false
	_jumped_this_flight = false
	sync_jumped = false
	if previous != State.AIRBORNE:
		return
	if new_state == State.IDLE or new_state == State.MOVE or new_state == State.DASH \
			or new_state == State.GRABBING:
		_resolve_fall_damage()
	# Caught a wall, grabbed, stunned or dead: nothing landed, so nothing hurts.


# B-d: the drop is reported, not charged. The owner is the one that sampled
# every frame of it, so it says where it fell from and where it landed; the
# server checks that against the height it watched and sets the damage.
func _resolve_fall_damage() -> void:
	last_fall_height = maxf(0.0, _fall_peak_y - global_position.y)
	if last_fall_height <= 0.0:
		return
	ServerAuthority.submit_intent(self, ServerAuthority.Intent.FALL, {
		"peak": _fall_peak_y,
		"land": global_position.y,
	})


# The one place the strength to weight numbers turn into movement. Nothing
# else may recompute them.
func get_ratio() -> float:
	return stats.ratio()


func get_jump_height() -> float:
	return Tuning.server.base_jump_height * Tuning.ratio_mult(get_ratio(), Tuning.server.ratio_k_jump)


func get_jump_velocity() -> float:
	return sqrt(2.0 * Tuning.server.gravity * get_jump_height())


# DOC (4-chapter, stage C-2): one budget for every leap, and three ways to
# spend it -- all of it up is a standing jump, half and half is the longest
# jump, all of it sideways is the dash. It lives here rather than in the
# movement script because the server judges speeds with it too, and a number
# two files work out for themselves is a number they will eventually disagree
# about.
func leap_speed_cap() -> float:
	var jump_max := get_jump_velocity()
	var move_max := get_move_speed()
	return sqrt(jump_max * jump_max + move_max * move_max)


# The farthest a leap can reach: a launch at the cap, at 45 degrees.
func leap_max_range() -> float:
	var cap := leap_speed_cap()
	return cap * cap / maxf(Tuning.server.gravity, 0.01)


func dash_speed() -> float:
	return leap_speed_cap() * Tuning.server.dash_speed_mult


# The one move-speed formula. It was written twice -- here and in
# PlayerMovement.move_speed() -- which is hazard 8 exactly: two copies of a
# number that have to agree, each consistent with itself. H-2 needed to add the
# race multiplier to it, so PlayerMovement now asks this instead of its own.
func get_move_speed() -> float:
	var mult := Tuning.ratio_mult(get_ratio(), Tuning.server.ratio_k_speed)
	# The race multiplier is the server's table, replicated to every peer, so
	# the speed this body walks at and the speed the server checks it against
	# come out of the same numbers.
	var judge := ServerAuthority.instance
	var race_mult := judge.race_move_mult(stats.race) if judge != null else 1.0
	return Tuning.server.base_move_speed * mult * race_mult


func default_snap_length() -> float:
	return _default_snap


# Standing on the ground, whatever the hands are doing. GRABBING belongs here:
# stage E takes out the rules that forbade jumping, dashing and shoving while
# carrying something, and every one of them was written as "is this body
# grounded" -- so a holder that was not grounded was a holder that could not
# act.
func is_grounded_state() -> bool:
	return state == State.IDLE or state == State.MOVE or state == State.GRABBING \
		or state == State.CASTING or state == State.RECOVERING


# M-4: how big this body is, off its race's height against the human's. 1.0 for
# a human; an orc at 220 cm is 1.22, a dwarf at 150 is 0.83.
func body_scale() -> float:
	if stats == null:
		return 1.0
	return stats.height_cm / maxf(Races.data_for(Races.DEFAULT).height_cm, 1.0)


func half_height() -> float:
	return BODY_HALF_HEIGHT * body_scale()


func radius() -> float:
	return BODY_RADIUS * body_scale()


# Sizes the capsule, the mesh, the shadow, the label and the agent to the race.
# Run on every peer when the race changes -- the server wrote it, the Vitals
# synchronizer carried it -- so the body the server judges with and the body
# each screen shows are the same size.
func _apply_body_size() -> void:
	if stats == null or _body_shape == null:
		return
	_body_race = stats.race
	var r := radius()
	var h := half_height()
	_body_shape.radius = r
	_body_shape.height = h * 2.0
	_body_mesh.radius = r
	_body_mesh.height = h * 2.0
	if _facing != null:
		_facing.position = Vector3(0.0, 0.2 * body_scale(), -(r + 0.18))
	if _shadow != null:
		(_shadow.mesh as QuadMesh).size = Vector2(r * 2.4, r * 2.4)
	if _label != null:
		_label.position = Vector3(0.0, h + 0.55, 0.0)
	if movement != null:
		movement.refresh_body_size()
	print("PLAYGROUND_BODY_SIZE peer=%s race=%s radius=%.2f half_height=%.2f" % [
		name, Races.label_for(stats.race), r, h])


# M-1: in a cast's windup or recovery. Nothing else may be ordered meanwhile.
func is_casting() -> bool:
	return state == State.CASTING or state == State.RECOVERING


# M-2: nothing may be ordered -- a cast's windup or recovery, or lying down.
func is_incapacitated() -> bool:
	return is_casting() or state == State.DOWNED


# The lying-down pose, 0 standing to 1 flat. Remote bodies lie flat for the
# whole of DOWNED; the owner eases back up through the getup.
func _lying() -> float:
	if state != State.DOWNED:
		return 0.0
	if is_local() and _down_left <= 0.0 and _getup_left > 0.0:
		return clampf(_getup_left / maxf(Tuning.server.getup_time, 0.01), 0.0, 1.0)
	return 1.0


# The stats half of the step, run on every peer and on every body: the side
# that owns the Vitals synchronizer publishes what the server ruled, and
# everyone else takes it. Separate from the pose half below, because the two
# halves have different owners -- the pose is the body's own machine and the
# abilities are the server's.
func _sync_stats() -> void:
	if stats == null:
		return
	if vitals_are_mine():
		sync_race = stats.race
		sync_strength_override = stats.strength_override
		sync_weight_override = stats.weight_override
		sync_gear_weight = stats.gear_weight
		return
	if Races.is_known(sync_race):
		stats.race = sync_race
	stats.strength_override = sync_strength_override
	stats.weight_override = sync_weight_override
	stats.gear_weight = sync_gear_weight


func _physics_process(delta: float) -> void:
	_sync_stats()
	if stats != null and stats.race != _body_race:
		_apply_body_size()
	# M-5: the weapon follows the server's word on every peer, the owner too.
	if sync_weapon != weapon:
		_apply_weapon(sync_weapon)
		if skills != null:
			skills.fill_slots()
	_except_holder()
	if is_local():
		# The server owns the flag; this is the body catching up with it, which
		# covers a death ruled while the result message was still in flight.
		# The grace is the other direction: the respawn result is reliable and
		# can arrive before the flag packet that cleared the death, and without
		# it the body stood up and was put straight back down as dead.
		_respawn_echo_left = maxf(0.0, _respawn_echo_left - delta)
		if _knock_left > 0.0:
			# Ours to clear: the readout is written by the force we received,
			# so it is cleared on the same machine and replicated out again.
			_knock_left -= delta
			if _knock_left <= 0.0:
				sync_knock = ""
				_apply_state_colour()
		if _predicted_left > 0.0:
			_predicted_left -= delta
			if _predicted_left <= 0.0:
				# Nothing answered. The picture goes rather than sticks.
				clear_predicted()
		if sync_dead and state != State.DEAD and _respawn_echo_left <= 0.0:
			enter_dead_now()
		if state == State.STUNNED:
			_stun_left -= delta
			if _stun_left <= 0.0:
				change_state(State.IDLE)
		if _strike_left > 0.0:
			_strike_left -= delta
			if _strike_left <= 0.0 and _strike_box != null:
				_strike_box.visible = false
		if state == State.DOWNED:
			if _down_left > 0.0:
				_down_left -= delta
				if _down_left <= 0.0:
					_getup_left = Tuning.server.getup_time
			elif _getup_left > 0.0:
				_getup_left -= delta
				if _getup_left <= 0.0:
					change_state(State.IDLE)
			_apply_predicted_pose()
		if _teleport_blind_left > 0.0:
			# N-2: a correction snaps this body like a teleport, and arriving
			# inside someone is handled the same way: no collision for a moment.
			_teleport_blind_left -= delta
			if _teleport_blind_left <= 0.0:
				collision_layer = PLAYER_LAYER
		if _fall_tracking and state == State.AIRBORNE:
			_fall_peak_y = maxf(_fall_peak_y, global_position.y)
		if is_grounded_state():
			stamina = minf(stats.max_stamina, stamina + Tuning.server.stamina_regen * delta)
		# A maximum that fell (slider, race) takes the pool down with it.
		stamina = minf(stamina, stats.max_stamina)
		sync_stamina = stamina
		sync_position = global_position
		sync_yaw = rotation.y
		sync_state = state
		sync_jumped = _jumped_this_flight
		_update_shadow()
		return
	# Shown, not simulated, like the pose: the owner's number as last heard.
	stamina = sync_stamina
	# M-5: the cast's show, replayed from the owner's stamp. The strike box
	# times itself out here as it does on the owner.
	var stamp := "%s|%s|%.3f" % [sync_skill_id, sync_skill_phase, sync_skill_at]
	if stamp != _shown_skill_stamp:
		_shown_skill_stamp = stamp
		if sync_skill_at > 0.0:
			remote_phases_seen += 1
			last_remote_phase_delay = Time.get_unix_time_from_system() - sync_skill_at
		show_skill_phase(Skills.get_def(sync_skill_id) if sync_skill_id != "" else null, sync_skill_phase)
	if _strike_left > 0.0:
		_strike_left -= delta
		if _strike_left <= 0.0 and _strike_box != null:
			_strike_box.visible = false
	if _teleport_blind_left > 0.0:
		_teleport_blind_left -= delta
		if _teleport_blind_left <= 0.0:
			collision_layer = PLAYER_LAYER
	# N-3: a carried body is where the server put it, not where its owner says.
	var judge := ServerAuthority.instance
	var shown := sync_position
	if judge != null and judge.holder_of(self) != 0:
		if _has_held_position:
			shown = _held_position
	else:
		_has_held_position = false
	if global_position.distance_to(shown) > SyncRules.TELEPORT_STEP:
		# Put down at the far end rather than slid there. Easing across a
		# teleport drags this capsule through whatever is standing in between,
		# and the body it passes through is shoved out of the way at teleport
		# speed: in testing a respawn across the map threw the other player
		# seven metres and off the plaza. Collision is off for a moment so the
		# arrival does not shove anyone either.
		global_position = shown
		collision_layer = 0
		_teleport_blind_left = SyncRules.TELEPORT_BLIND
	else:
		# Remote bodies are shown, not simulated: a short lerp hides the gap
		# between state packets without letting them drift.
		global_position = global_position.lerp(shown, SyncRules.ease(delta))
	rotation.y = lerp_angle(rotation.y, sync_yaw, SyncRules.ease_yaw(delta))
	_update_shadow()
	if sync_state != state:
		change_state(sync_state)


# N-2: the server could not explain where this body went, and says where it
# last could. Pose is still ours -- we do the snapping -- but the order being
# carried out is dropped with it: a run, a dash, a target. Collision is off for
# a moment so the arrival does not shove anyone, the same as any teleport.
func apply_correction(at: Vector3) -> void:
	if not is_local():
		return
	corrections_received += 1
	if movement != null:
		movement.cancel_dash()
		movement.cancel_target()
	global_position = at
	velocity = Vector3.ZERO
	collision_layer = 0
	_teleport_blind_left = SyncRules.TELEPORT_BLIND
	print("PLAYGROUND_CORRECTED peer=%s to=(%.2f, %.2f, %.2f) count=%d" % [
		name, at.x, at.y, at.z, corrections_received])


# On every peer, every step: a body cannot be pushed by, or push, what is
# carrying it. The same exception a rock and a scarecrow keep.
func _except_holder() -> void:
	var judge := ServerAuthority.instance
	var holder_peer := judge.holder_of(self) if judge != null else 0
	var holder: Node3D = judge.actor_for(holder_peer) if holder_peer != 0 else null
	if holder == _excepted_holder:
		return
	if is_instance_valid(_excepted_holder):
		remove_collision_exception_with(_excepted_holder)
	_excepted_holder = null
	if holder != null:
		add_collision_exception_with(holder)
		_excepted_holder = holder


# N-3: the server's word on where this carried body is. Written on the server
# every step and on every other peer by push_held_position.
func set_held_position(at: Vector3) -> void:
	_held_position = at
	_has_held_position = true


func clear_held_position() -> void:
	_has_held_position = false


# The owner's half while carried: apply what the server sent, write nothing of
# our own. Until the first position arrives the body stays where it was taken.
func follow_held_position(delta: float) -> void:
	if not _has_held_position:
		return
	if global_position.distance_to(_held_position) > SyncRules.TELEPORT_STEP:
		global_position = _held_position
	else:
		global_position = global_position.lerp(_held_position, SyncRules.ease(delta))


# N-3: put down by the server, beside whoever held us. From here the pose is
# ours again.
func apply_release(at: Vector3) -> void:
	if not is_local():
		return
	clear_held_position()
	global_position = at
	velocity = Vector3.ZERO
	print("PLAYGROUND_RELEASED peer=%s at=(%.2f, %.2f, %.2f)" % [name, at.x, at.y, at.z])


# Set by the movement when a launch is this body's own jump, and cleared the
# moment it is on the ground again.
func note_jumped() -> void:
	_jumped_this_flight = true
	# Written here and not left to the next sync: the judge runs before the
	# players do, so a flag set only in _physics_process is a frame old by the
	# time the hold table looks at it -- and the table dropped what the body
	# was carrying on the first frame of every jump.
	sync_jumped = true


# Told by the server. The body is stopped and put in the state here, because
# the pose is still the owner's to write; whether it died at all was decided in
# one place, which is what B-a's "nothing overwrites DEAD" needed.
# Where the floor is under this body, and how far above it the body is. Run for
# every body on every peer: a remote character needs its blob as much as a
# local one does.
func _update_shadow() -> void:
	if _shadow == null:
		return
	var from := global_position
	var query := PhysicsRayQueryParameters3D.create(
		from, from + Vector3.DOWN * SHADOW_REACH, Layers.TERRAIN | Layers.THROWABLE)
	query.collide_with_areas = false
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		_shadow.visible = false
		return
	var ground: Vector3 = hit["position"]
	# Just clear of the surface, or it fights with the floor it is drawn on.
	_shadow.global_position = ground + Vector3.UP * 0.02
	_shadow.global_rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	var height := maxf(0.0, from.y - half_height() - ground.y)
	var closeness: float = 1.0 - clampf(height / SHADOW_FADE_HEIGHT, 0.0, 1.0)
	var size: float = lerpf(SHADOW_MIN_SCALE, 1.0, closeness)
	_shadow.scale = Vector3(size, size, 1.0)
	var material := _shadow.material_override as StandardMaterial3D
	material.albedo_color.a = lerpf(0.12, 0.35, closeness)
	_shadow.visible = true


func enter_dead_now() -> void:
	if not is_local() or state == State.DEAD:
		return
	velocity = Vector3.ZERO
	if movement != null:
		movement.cancel_target()
	change_state(State.DEAD)


# Also the R key: a restart is the same thing as coming back from a fall, so
# there is one path rather than two that can drift apart. The vitals half is
# the server's, the mark and the state are ours.
func respawn() -> void:
	if not is_local():
		return
	if vitals_are_mine():
		ServerAuthority.instance.server_respawn(self)
		return
	# N-4: alive or dead, the mark is the server's to choose. The answer carries
	# it, and apply_respawn below does the moving when it arrives.
	ServerAuthority.submit_intent(self, ServerAuthority.Intent.RESPAWN, {})


# The owner's half of a respawn, run once the server has cleared the vitals and
# chosen the mark. Pose is ours, so the move is made here, to where it said.
func apply_respawn(at: Vector3) -> void:
	if not is_local():
		return
	# Our copy of the server's flag, brought forward by one packet. The server
	# set it false before sending this; the replica confirms it a moment later.
	sync_dead = false
	_respawn_echo_left = RESPAWN_ECHO_GRACE
	global_position = at
	# N-4: a teleport, so no collision for a moment. Jolt reads a kinematic
	# body's velocity off its motion, and a rock resting on this head left at
	# the teleport's speed -- 220 m/s, measured -- when the body moved without
	# this. The same blind every other snap in the game uses.
	collision_layer = 0
	_teleport_blind_left = SyncRules.TELEPORT_BLIND
	velocity = Vector3.ZERO
	stamina = stats.max_stamina
	respawns_applied += 1
	floor_snap_length = _default_snap
	if movement != null:
		movement.cancel_target()
	_fall_tracking = false
	_respawning = true
	change_state(State.IDLE)
	_respawning = false
	print("PLAYGROUND_RESPAWN peer=%s at=%s" % [name, global_position])


# Picked up by standing on a rack pedestal. M-3: a request -- the rack asks for
# a kind and the server rules. M-5: the answer is the server's sync_weapon on
# the Vitals synchronizer, applied by every peer in _physics_process; nothing
# on the owner writes the weapon itself any more.
func set_weapon(kind: int) -> void:
	if not is_local() or kind == weapon:
		return
	ServerAuthority.submit_intent(self, ServerAuthority.Intent.WEAPON, {"weapon": kind})


# The picture of the weapon. Only ever called with the server's value.
func _apply_weapon(kind: int) -> void:
	weapon = kind
	if is_instance_valid(_weapon_node):
		_weapon_node.queue_free()
	_weapon_node = null
	if kind == WeaponKinds.Kind.NONE:
		return
	_weapon_node = WeaponKinds.build_mesh(kind)
	_weapon_node.name = "HeldWeapon"
	# At the hand, pointing the way the body faces.
	_weapon_node.position = Vector3(0.34, 0.1, -0.1)
	_visual.add_child(_weapon_node)


# Square on to the wall, facing into it, with no easing: the body is placed on
# the wall in one step so the first frame of climbing already looks right.
# Where every push in the game lands. ForceSystem routes here, and nothing else
# writes this body's velocity from outside.
func apply_force_event(event: Dictionary) -> void:
	if not is_local() or state == State.DEAD or sync_dead:
		return
	# 4-chapter, in one call: the push scaled by the pusher's strength against
	# our weight. v4 deleted the term that let our own strength hold part of a
	# push back, so strength no longer shortens this -- it decided the verdict
	# below instead.
	var change := ForceSystem.change_for(event, stats.total_weight())
	# v4's knockback verdict, ruled by the server before the event was sent. We
	# apply what we were handed and never work one out for ourselves. Absent
	# means nobody ruled -- a force raised with no server in the loop -- and
	# then the old rule stands: the push lands whole.
	var launched := bool(event.get("knock_launched", true))
	if not launched:
		# Within tolerance: we hold our ground. Only the horizontal is kept,
		# the existing slide window carries it, and nothing below stuns us.
		change.y = 0.0
	_show_knock(event, launched)
	if grab != null and launched:
		# 7-6: being pushed frees a held body and empties a holder's hands --
		# but only a push that launched us. 결정 2: a body that slid keeps what
		# it is carrying, and the server's hold table agrees with this.
		grab.on_force_received()
	if climb != null and climb.is_climbing():
		# Knocked off the wall rather than pushed along it.
		climb.detach(0.0)
	if movement != null:
		# 4-chapter: a push becomes this body's velocity, and the ground step
		# must not write the move order over it on the next frame. Told for
		# every force, not only the ones that land on a grounded body: a body
		# freed from a hold at ground level is airborne for a single frame and
		# then lands, and the escape recoil was being wiped on that landing.
		movement.note_pushed()
	if bool(event.get("spring", false)):
		# Stage E follow-up: a team mate's push is a shield to jump off, not a
		# nudge. The vertical is replaced by this body's own jump -- the
		# standing jump, with whatever it is carrying in the weight -- and the
		# push is added to that. Replacing rather than adding is what makes the
		# result the same wherever in the arc the push arrives, which is what
		# made the co-op launch depend on the latency before.
		velocity.y = get_jump_velocity()
		if state != State.AIRBORNE:
			change_state(State.AIRBORNE)
			note_jumped()
	if state == State.AIRBORNE:
		# Already flying: the push bends the arc and costs nothing, which is
		# what makes throwing a team mate a thing you can help with.
		velocity += change
	else:
		velocity = change
		if launched:
			# Over the tolerance: this is leaving the ground, so it leaves the
			# ground properly. Without the floor the up component is whatever
			# the push's own angle gave it, and a flat shove would have read as
			# a launch while the body never came off the floor -- which is the
			# one thing the two words have to tell apart.
			if velocity.y < Tuning.server.launch_min_up_speed:
				velocity.y = Tuning.server.launch_min_up_speed
			change_state(State.AIRBORNE)
	# B-d: whether this hurt, and whether it stuns, was decided by the server
	# before the event was sent. stun_apply is that verdict: v4 fills it in for
	# a launch, M-7 for a caught attack whatever the push did.
	var stun := float(event.get("stun_apply", 0.0))
	if stun > 0.0 and state != State.DEAD:
		_apply_stun(stun)
	# M-2: the knockdown, ruled by the server like the stun. Applied whether or
	# not the push launched us -- a kick that fails to move a heavy body still
	# puts it down -- and a second one lands the body down for the full time.
	var down := float(event.get("down_apply", 0.0))
	if down > 0.0:
		_apply_down(down)
	print("PLAYGROUND_FORCE peer=%s power=%.2f verdict=%s airborne=%s hp=%.0f vel=(%.2f, %.2f, %.2f) y=%.2f" % [
		name, change.length(), "launched" if launched else "slid",
		state == State.AIRBORNE, hp,
		velocity.x, velocity.y, velocity.z, global_position.y])


# The debug readout the work order asks for: the last force event's h_speed
# against the tolerance it was compared with, over the target's head. On the
# owner's synchronizer rather than a local label, because the person who wants
# to read it is usually the one who did the pushing.
func _show_knock(event: Dictionary, launched: bool) -> void:
	if not event.has("knock_tolerance"):
		return
	if not bool(event.get("knock_judged", true)):
		# Nothing to compare: a push with no horizontal part is not knockback.
		return
	sync_knock = "%.1f / %.1f %s" % [
		float(event.get("knock_h_speed", 0.0)),
		float(event.get("knock_tolerance", 0.0)),
		"튕겨나감" if launched else "미끄러짐"]
	_knock_left = KNOCK_SHOW_TIME
	_apply_state_colour()


func _apply_stun(seconds: float) -> void:
	if state == State.DEAD or sync_dead:
		return
	_stun_left = seconds
	if movement != null:
		movement.cancel_target()
	change_state(State.STUNNED)


# M-2: knocked down. Lying for `seconds`, then getup_time standing up; no
# orders through either, pushes still land. Already down resets the clock.
func _apply_down(seconds: float) -> void:
	if state == State.DEAD or sync_dead or state == State.GRABBED:
		return
	_down_left = seconds
	_getup_left = 0.0
	downs_applied += 1
	if movement != null:
		movement.cancel_target()
		movement.cancel_armed()
	if climb != null and climb.is_climbing():
		climb.detach(0.0)
	if state != State.DOWNED:
		change_state(State.DOWNED)
	_apply_predicted_pose()
	print("PLAYGROUND_DOWNED peer=%s for=%.2f" % [name, seconds])


# Instant, unlike face_direction: a shove points the body where it was aimed
# before the push goes out, not a few frames later.
func snap_facing(direction: Vector3) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0004:
		return
	rotation.y = atan2(-flat.x, -flat.z)


func hand_position() -> Vector3:
	return global_position + Vector3.UP * (half_height() + HAND_HEIGHT * body_scale())


func set_overhead_note(text: String) -> void:
	overhead_note = text
	_apply_state_colour()


# Written by ServerAuthority's hold table and by nothing else. A person being
# carried is shown by their own GRABBED state, which their machine sets when it
# reads the row; this is the other direction, for everyone else's screen.
func set_hold_display(peer: int) -> void:
	holder_peer = peer


func _peer_player(peer_id: int) -> Player:
	if get_parent() == null:
		return null
	return get_parent().get_node_or_null(str(peer_id)) as Player


func look_at_wall(normal: Vector3) -> void:
	rotation.y = atan2(normal.x, normal.z)


func face_direction(direction: Vector3, delta: float, turn_speed: float = 16.0) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0004:
		return
	var wanted := atan2(-flat.x, -flat.z)
	rotation.y = lerp_angle(rotation.y, wanted, 1.0 - exp(-turn_speed * delta))


func _build_body() -> void:
	var collision := CollisionShape3D.new()
	collision.name = "BodyShape"
	var shape := CapsuleShape3D.new()
	shape.radius = BODY_RADIUS
	shape.height = BODY_HALF_HEIGHT * 2.0
	collision.shape = shape
	_body_shape = shape
	add_child(collision)

	_visual = Node3D.new()
	_visual.name = "Visual"
	add_child(_visual)

	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = BODY_RADIUS
	capsule.height = BODY_HALF_HEIGHT * 2.0
	body.mesh = capsule
	_body_mesh = capsule
	_material = StandardMaterial3D.new()
	_material.roughness = 0.7
	body.material_override = _material
	_visual.add_child(body)

	var facing := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.16
	cone.height = 0.5
	facing.mesh = cone
	facing.rotation_degrees.x = 90.0
	facing.position = Vector3(0.0, 0.2, -0.58)
	var facing_material := StandardMaterial3D.new()
	facing_material.albedo_color = Color.WHITE
	facing.material_override = facing_material
	_visual.add_child(facing)
	_facing = facing

	# A blob on the ground under the body. top_level, so the parent transform
	# does not carry it up with the body: it stays on the floor, and the gap
	# between the two is what says how high this body is. Cosmetic only -- no
	# collision, its own render layer, built on every peer rather than
	# replicated.
	_shadow = MeshInstance3D.new()
	_shadow.name = "FootShadow"
	_shadow.top_level = true
	var blob := QuadMesh.new()
	blob.size = Vector2(BODY_RADIUS * 2.4, BODY_RADIUS * 2.4)
	_shadow.mesh = blob
	_shadow.rotation_degrees.x = -90.0
	_shadow.layers = SHADOW_LAYER
	_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var blob_material := StandardMaterial3D.new()
	blob_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	blob_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	blob_material.albedo_color = Color(0.0, 0.0, 0.0, 0.35)
	blob_material.no_depth_test = false
	_shadow.material_override = blob_material
	add_child(_shadow)

	# M-1: the strike, shown as a box pushed out of the body for a moment. Size
	# and height come off the SkillDef when it is shown; hidden otherwise.
	_strike_box = MeshInstance3D.new()
	_strike_box.name = "StrikeBox"
	_strike_box.mesh = BoxMesh.new()
	var strike_material := StandardMaterial3D.new()
	strike_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_strike_box.material_override = strike_material
	_strike_box.visible = false
	_visual.add_child(_strike_box)

	_label = Label3D.new()
	_label.position = Vector3(0.0, 1.45, 0.0)
	_label.font_size = 26
	_label.outline_size = 6
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	add_child(_label)
	_apply_state_colour()


# How long a press is shown while nothing has answered it. Long enough for a
# 200 ms round trip and the ruling at the far end, short enough that a lost
# answer does not leave the body posing.
const PREDICT_SHOW := 0.8
const PREDICT_NAMES := {
	ServerAuthority.Intent.SHOVE: "밀치기",
	ServerAuthority.Intent.GRAB: "잡기",
	ServerAuthority.Intent.THROW: "던지기",
	ServerAuthority.Intent.ESCAPE: "탈출",
	ServerAuthority.Intent.SKILL: "기술",
}


# Shown on the frame of the press, by the machine that pressed.
func begin_predicted(kind: int) -> void:
	if not is_local():
		return
	predicted_action = kind
	predicted_at_msec = Time.get_ticks_msec()
	_predicted_left = PREDICT_SHOW
	_apply_predicted_pose()
	_apply_state_colour()


# A picture that is being held rather than waited on: the throw pose while
# the key stays down. Started like a press, and kept from timing out for as
# long as this is called every step.
func hold_predicted(kind: int) -> void:
	if not is_local():
		return
	if predicted_action != kind:
		begin_predicted(kind)
		return
	_predicted_left = PREDICT_SHOW


# The answer arrived, or the server refused, or nothing came at all.
func clear_predicted() -> void:
	if predicted_action == -1:
		return
	predicted_action = -1
	_predicted_left = 0.0
	_apply_predicted_pose()
	_apply_state_colour()


# The whole of the motion: a lean towards whatever was aimed at. Deliberately
# small -- it has to be taken back without looking like a glitch when the
# server says no.
func _apply_predicted_pose() -> void:
	if _visual == null:
		return
	var leaning := predicted_action != -1
	# M-1: the cast's own lean adds to the prediction's. M-2: a body that was
	# knocked down lies flat, and eases back up through the getup.
	var lying := _lying()
	_visual.rotation.x = deg_to_rad(-(12.0 if leaning else 0.0) - _skill_lean_deg - 85.0 * lying)
	_visual.position.y = (-0.08 if leaning else 0.0) - (half_height() - radius()) * lying


# M-1: the procedural show, one phase at a time. "windup" leans the capsule
# into the strike, "strike" pushes the box out for a moment, "recovery" leans
# it back; null ends it. Every number is the SkillDef's.
func show_skill_phase(def: SkillDef, phase: String) -> void:
	if is_local():
		# M-5: stamped for the other screens, which replay the same hooks.
		sync_skill_id = def.id if def != null else ""
		sync_skill_phase = phase
		sync_skill_at = Time.get_unix_time_from_system()
	if def == null or phase == "":
		_skill_lean_deg = 0.0
		if _strike_box != null:
			_strike_box.visible = false
		_apply_predicted_pose()
		return
	match phase:
		"windup":
			_skill_lean_deg = def.windup_lean_deg
		"recovery":
			_skill_lean_deg = def.recovery_lean_deg
		"strike":
			_skill_lean_deg = def.windup_lean_deg * 0.5
			if _strike_box != null:
				var box := _strike_box.mesh as BoxMesh
				box.size = Vector3(0.25, 0.25, def.strike_extent)
				_strike_box.position = Vector3(0.0, def.strike_height * body_scale(), -(radius() + def.strike_extent * 0.5))
				(_strike_box.material_override as StandardMaterial3D).albedo_color = def.colour
				_strike_box.visible = true
				_strike_left = PlayerSkills.STRIKE_SHOW
	_apply_predicted_pose()


func _apply_state_colour() -> void:
	if _material != null:
		var colour := Color(STATE_COLORS.get(state, "6fa8dc"))
		if predicted_action != -1:
			# Brighter while a press is waiting on its answer.
			colour = colour.lerp(Color.WHITE, 0.35)
		_material.albedo_color = colour
	if _label != null:
		_label.text = "%s · %s" % [name, State.keys()[state]]
		if predicted_action != -1:
			_label.text += " (%s?)" % PREDICT_NAMES.get(predicted_action, "동작")
		if overhead_note != "":
			_label.text += "\n" + overhead_note
		if sync_knock != "":
			_label.text += "\n" + sync_knock
