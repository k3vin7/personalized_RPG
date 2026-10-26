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
	DEAD,
}

# Names kept for the call sites; the numbers live in Layers and nowhere else.
const WORLD_LAYER := Layers.WORLD
const WALL_LAYER := Layers.WALL
const CLIMBABLE_LAYER := Layers.CLIMBABLE
const PLAYER_LAYER := Layers.PLAYER
const THROWABLE_LAYER := Layers.THROWABLE

const BODY_RADIUS := 0.4
const BODY_HALF_HEIGHT := 0.9
# DOC: a held rock or team mate sits 0.8 m above the head, where it is visible
# on both screens and clear of the holder's own body.
const HAND_HEIGHT := 0.8
# A replicated step bigger than this is a teleport, not travel: a respawn, a
# test placement, or a large correction.
const TELEPORT_STEP := 2.0
const TELEPORT_BLIND := 0.2

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
# The stats travel too: a shove is worked out from the pusher's strength
# against the target's weight, so every peer needs the target's numbers.
var sync_strength := 10.0
var sync_race_weight := 10.0
var sync_gear_weight := 0.0
var sync_weapon: int = WeaponKinds.Kind.NONE

var movement: PlayerMovement
var climb: PlayerClimb
var grab: PlayerGrab
var stamina := 100.0
var camera: QuarterCamera

var _visual: Node3D
# The camera, the HUD bars and the debug panel: ours to free when we go.
var _owned_views: Array[Node] = []
var _material: StandardMaterial3D
var _label: Label3D
var _default_snap := 0.3
var spawn_point := Vector3.ZERO
var _stun_left := 0.0
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
	stamina = Tuning.values.stamina_max
	collision_layer = PLAYER_LAYER
	# Rocks are included: a rock you can walk through is not a thing you would
	# bother picking up, and a thrown one has to be able to knock you about.
	collision_mask = Layers.SOLID_PLAYER
	floor_snap_length = _default_snap
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
	if previous != State.AIRBORNE:
		return
	if new_state == State.IDLE or new_state == State.MOVE or new_state == State.DASH:
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
	return Tuning.values.base_jump_height * Tuning.ratio_mult(get_ratio(), Tuning.values.ratio_k_jump)


func get_jump_velocity() -> float:
	return sqrt(2.0 * Tuning.values.gravity * get_jump_height())


func get_move_speed() -> float:
	return Tuning.values.base_move_speed * Tuning.ratio_mult(get_ratio(), Tuning.values.ratio_k_speed)


func default_snap_length() -> float:
	return _default_snap


func is_grounded_state() -> bool:
	return state == State.IDLE or state == State.MOVE


func _physics_process(delta: float) -> void:
	if is_local():
		# The server owns the flag; this is the body catching up with it, which
		# covers a death ruled while the result message was still in flight.
		# The grace is the other direction: the respawn result is reliable and
		# can arrive before the flag packet that cleared the death, and without
		# it the body stood up and was put straight back down as dead.
		_respawn_echo_left = maxf(0.0, _respawn_echo_left - delta)
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
		if _fall_tracking and state == State.AIRBORNE:
			_fall_peak_y = maxf(_fall_peak_y, global_position.y)
		if is_grounded_state():
			stamina = minf(Tuning.values.stamina_max, stamina + Tuning.values.stamina_regen * delta)
		sync_position = global_position
		sync_yaw = rotation.y
		sync_state = state
		sync_strength = stats.strength
		sync_race_weight = stats.race_weight
		sync_gear_weight = stats.gear_weight
		sync_weapon = weapon
		return
	stats.strength = sync_strength
	stats.race_weight = sync_race_weight
	stats.gear_weight = sync_gear_weight
	if sync_weapon != weapon:
		_apply_weapon(sync_weapon)
	if _teleport_blind_left > 0.0:
		_teleport_blind_left -= delta
		if _teleport_blind_left <= 0.0:
			collision_layer = PLAYER_LAYER
	if global_position.distance_to(sync_position) > TELEPORT_STEP:
		# Put down at the far end rather than slid there. Easing across a
		# teleport drags this capsule through whatever is standing in between,
		# and the body it passes through is shoved out of the way at teleport
		# speed: in testing a respawn across the map threw the other player
		# seven metres and off the plaza. Collision is off for a moment so the
		# arrival does not shove anyone either.
		global_position = sync_position
		collision_layer = 0
		_teleport_blind_left = TELEPORT_BLIND
	else:
		# Remote bodies are shown, not simulated: a short lerp hides the gap
		# between state packets without letting them drift.
		global_position = global_position.lerp(sync_position, 1.0 - exp(-18.0 * delta))
	rotation.y = lerp_angle(rotation.y, sync_yaw, 1.0 - exp(-20.0 * delta))
	if sync_state != state:
		change_state(sync_state)


# Told by the server. The body is stopped and put in the state here, because
# the pose is still the owner's to write; whether it died at all was decided in
# one place, which is what B-a's "nothing overwrites DEAD" needed.
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
	ServerAuthority.submit_intent(self, ServerAuthority.Intent.RESPAWN, {})
	if not sync_dead:
		# Alive, so this is the debug "back to a mark", and a mark is pose --
		# which is still ours to write. It happens now and the server's half,
		# topping the HP back up, arrives on its own.
		#
		# A dead body does not get this: leaving DEAD is the server's ruling and
		# its clock, which is what keeps a death decided once.
		apply_respawn()


# The owner's half of a respawn, run once the server has cleared the vitals.
func apply_respawn() -> void:
	if not is_local():
		return
	# Our copy of the server's flag, brought forward by one packet. The server
	# set it false before sending this; the replica confirms it a moment later.
	sync_dead = false
	_respawn_echo_left = RESPAWN_ECHO_GRACE
	global_position = _free_spawn_point()
	velocity = Vector3.ZERO
	stamina = Tuning.values.stamina_max
	floor_snap_length = _default_snap
	if movement != null:
		movement.cancel_target()
	_fall_tracking = false
	_respawning = true
	change_state(State.IDLE)
	_respawning = false
	print("PLAYGROUND_RESPAWN peer=%s at=%s" % [name, global_position])


# DOC: an empty spawn point, not necessarily our own: two bodies arriving on the
# same mark shove each other off it.
func _free_spawn_point() -> Vector3:
	var points := Net.spawn_points
	if points.is_empty():
		return spawn_point
	var neighbours: Array[Node] = get_parent().get_children() if get_parent() != null else []
	for point in points:
		var taken := false
		for node in neighbours:
			var body := node as Node3D
			if body == null or body == self:
				continue
			if Vector2(body.global_position.x - point.x, body.global_position.z - point.z).length() < 1.2:
				taken = true
				break
		if not taken:
			return point
	return points[0]


# Picked up by standing on a rack pedestal. Only the body's owner may change it;
# everyone else receives it through sync_weapon.
func set_weapon(kind: int) -> void:
	if not is_local() or kind == weapon:
		return
	_apply_weapon(kind)
	print("PLAYGROUND_WEAPON peer=%s kind=%s" % [name, WeaponKinds.LABELS.get(kind, "?")])


func _apply_weapon(kind: int) -> void:
	weapon = kind
	sync_weapon = kind
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
	var direction: Vector3 = event.get("direction", Vector3.ZERO)
	var change := direction * ForceSystem.power_for(event, stats.total_weight())
	if grab != null:
		# 7-6: being pushed frees a held body and empties a holder's hands. The
		# force then applies to whatever state that left us in.
		grab.on_force_received()
	if climb != null and climb.is_climbing():
		# Knocked off the wall rather than pushed along it.
		climb.detach(0.0)
	if state == State.AIRBORNE:
		# Already flying: the push bends the arc and costs nothing, which is
		# what makes throwing a team mate a thing you can help with.
		velocity += change
	else:
		velocity = change
		if change.y > ForceSystem.UPWARD_LAUNCH:
			change_state(State.AIRBORNE)
		# B-d: whether this hurt, and whether it stuns, was decided by the
		# server before the event was sent. stun_apply is that verdict.
		var stun := float(event.get("stun_apply", 0.0))
		if stun > 0.0:
			_apply_stun(stun)
	print("PLAYGROUND_FORCE peer=%s power=%.2f airborne=%s hp=%.0f vel=(%.2f, %.2f, %.2f) y=%.2f" % [
		name, change.length(), state == State.AIRBORNE, hp,
		velocity.x, velocity.y, velocity.z, global_position.y])


func _apply_stun(seconds: float) -> void:
	if state == State.DEAD or sync_dead:
		return
	_stun_left = seconds
	if movement != null:
		movement.cancel_target()
	change_state(State.STUNNED)


# Instant, unlike face_direction: a shove points the body where it was aimed
# before the push goes out, not a few frames later.
func snap_facing(direction: Vector3) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0004:
		return
	rotation.y = atan2(-flat.x, -flat.z)


func hand_position() -> Vector3:
	return global_position + Vector3.UP * (BODY_HALF_HEIGHT + HAND_HEIGHT)


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
	var shape := CapsuleShape3D.new()
	shape.radius = BODY_RADIUS
	shape.height = BODY_HALF_HEIGHT * 2.0
	collision.shape = shape
	add_child(collision)

	_visual = Node3D.new()
	_visual.name = "Visual"
	add_child(_visual)

	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = BODY_RADIUS
	capsule.height = BODY_HALF_HEIGHT * 2.0
	body.mesh = capsule
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
	_visual.rotation.x = deg_to_rad(-12.0) if leaning else 0.0
	_visual.position.y = -0.08 if leaning else 0.0


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
