class_name Dummy
extends CharacterBody3D

# A thing to push. Owned by the host, as the design doc's table requires for
# anything that is not a player's own body, and it walks itself back to where it
# started so the next shove starts from the same place.

const LAYER := Layers.DUMMY
const RETURN_DELAY := 2.0
const RETURN_SPEED := 2.0
const MAX_HP := 60.0

# The one place a scarecrow's weight is written. It used to be here as
# MAX_HP * 0.2 for the push and again in ServerAuthority as DUMMY_WEIGHT = 12.0
# for the lift limit: two expressions in two files that happened to agree, which
# is the shape CLAUDE.md's eighth note warns about. The lift limit reads this.
const WEIGHT := 12.0
# The capsule, in one place: the judge's height band and radius for a scarecrow
# and the spot it is released to both read these.
const RADIUS := 0.4
const HALF_HEIGHT := 0.9
# 20 state packets a second. A dummy built in code has no synchronizer of its
# own, so the host pushes its state: without this a client saw a dummy that
# never moved however hard it was shoved.
# Further than this in one state packet and the position is snapped with
# collision off for a moment, rather than lerped through whatever is in the
# way. Same numbers the rock uses, for the same reason.

var home := Vector3.ZERO
var hp := MAX_HP
# A read-only copy of a row in ServerAuthority's hold table. A scarecrow joins
# the table in B-c so that one table covers every kind of body; being picked up
# is enabled in stage E, where can_grab() stops refusing it.
var holder_peer := 0
var sync_position := Vector3.ZERO
var sync_hp := MAX_HP

var _settle_left := 0.0
var _state_left := 0.0
var _has_state := false
var _excepted: Node3D = null
var _blind_left := 0.0
var _label: Label3D
var _material: StandardMaterial3D
# M-7: the attack pattern, a stand-in for a boss swing. Every period a windup
# it shows (the colour and a "!" above it), then a strike in front, booked and
# ruled by ServerAuthority like a player's. Server-side clock; the phase
# travels in push_state so every screen shows the windup.
var _attack_timer := 0.0
var _phase_left := 0.0
var attack_phase := ""
var attacks_made := 0


func setup(at_position: Vector3, dummy_name: String) -> void:
	position = at_position
	name = dummy_name


func _enter_tree() -> void:
	# The host owns it. Every peer builds the same dummy in the same place, so
	# only its state has to travel.
	set_multiplayer_authority(1)


func _ready() -> void:
	home = global_position
	sync_position = global_position
	add_to_group(ServerAuthority.HOLDABLE_GROUP)
	collision_layer = LAYER
	# Was terrain only, which is why a player walked straight through a
	# scarecrow and two scarecrows could stand in the same spot.
	collision_mask = Layers.SOLID_DUMMY

	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = RADIUS
	shape.height = HALF_HEIGHT * 2.0
	collision.shape = shape
	add_child(collision)

	var mesh_instance := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = RADIUS
	capsule.height = HALF_HEIGHT * 2.0
	mesh_instance.mesh = capsule
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color("c9b48a")
	mesh_instance.material_override = _material
	add_child(mesh_instance)

	_label = Label3D.new()
	_label.position = Vector3(0.0, 1.5, 0.0)
	_label.font_size = 28
	_label.outline_size = 6
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	add_child(_label)
	_refresh()
	set_physics_process(true)


# The single entry point's landing place. A dummy is not an ally, so a push from
# a player hurts it whatever the ally flags say.
func apply_force_event(event: Dictionary) -> void:
	if not is_multiplayer_authority():
		return
	# Stage D: in the air the push is added, not written over. A scarecrow was
	# the one body that still overwrote, so a second shove while it was flying
	# replaced the first one instead of bending its arc.
	var change := ForceSystem.change_for(event, WEIGHT)
	if is_on_floor():
		velocity = change
	else:
		velocity += change
	hp = maxf(0.0, hp - float(event.get("damage", 0.0)))
	_settle_left = RETURN_DELAY
	_refresh()
	print("PLAYGROUND_DUMMY_HIT name=%s hp=%.0f push=%.2f" % [name, hp, velocity.length()])


func set_hold_display(peer: int) -> void:
	holder_peer = peer
	if is_multiplayer_authority() and peer == 0:
		# Put down: it settles where it was left rather than snapping home.
		_settle_left = RETURN_DELAY


# Server only: where the hand lets go of it. Written by the judge when the
# hold ends, the way a person is put beside their holder (N-5); left at the
# hand it stood on the holder's head, because a capsule's foot at the hand's
# height is exactly the top of the holder's capsule.
func release_to(at: Vector3) -> void:
	if not is_multiplayer_authority():
		return
	global_position = at
	velocity = Vector3.ZERO
	sync_position = at


func _physics_process(delta: float) -> void:
	# On every peer, before anything else: a body cannot be pushed by what is
	# carrying it. Without this the scarecrow was written into the holder's
	# hand each step, the two capsules overlapped, and the solver pushed the
	# holder out -- which read as the walk speed suddenly shooting up while
	# carrying one. The rock has had this since stage E; the scarecrow is held
	# by the same table and needed the same thing.
	_except_holder()
	if _blind_left > 0.0:
		_blind_left = maxf(0.0, _blind_left - delta)
		if _blind_left == 0.0:
			collision_layer = LAYER
	if is_multiplayer_authority() and holder_peer != 0:
		# Stage E: a scarecrow can be picked up, and a held body rides the hand
		# rather than walking itself home. Whether the hold still stands is the
		# table's ruling, the same one every other held body gets.
		var hands := _peer_player(holder_peer)
		if hands != null:
			global_position = hands.hand_position()
			velocity = Vector3.ZERO
			_settle_left = RETURN_DELAY
			sync_position = global_position
			_state_left -= delta
			if _state_left <= 0.0 and multiplayer.has_multiplayer_peer():
				_state_left = SyncRules.STATE_INTERVAL
				push_state.rpc(global_position, hp)
			return
	if not is_multiplayer_authority():
		# Shown, not simulated.
		if not _has_state:
			return
		if global_position.distance_to(sync_position) > SyncRules.TELEPORT_STEP:
			# Carried across the plaza, or thrown: lerping that would drag the
			# capsule through everyone on the way at teleport speed.
			global_position = sync_position
			_blind_left = SyncRules.TELEPORT_BLIND
			collision_layer = 0
		else:
			global_position = global_position.lerp(sync_position, SyncRules.ease(delta))
		if not is_equal_approx(hp, sync_hp):
			hp = sync_hp
			_refresh()
		return

	if not is_on_floor():
		velocity.y -= Tuning.server.gravity * delta
	elif velocity.y <= 0.0:
		# Only pressed into the floor when it is not trying to leave it. This
		# used to be unconditional, so an upward force was written back to
		# -0.5 on the same frame and a scarecrow could not be launched at all
		# -- it had only ever been shoved sideways, so nobody had noticed.
		velocity.y = -0.5
		velocity.x = move_toward(velocity.x, 0.0, 12.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 12.0 * delta)

	_settle_left = maxf(0.0, _settle_left - delta)
	if _settle_left == 0.0 and is_on_floor():
		# Back to its mark, so the next push starts where the last one did.
		var to_home := home - global_position
		to_home.y = 0.0
		if to_home.length() > 0.2:
			velocity.x = to_home.normalized().x * RETURN_SPEED
			velocity.z = to_home.normalized().z * RETURN_SPEED
		elif hp < MAX_HP:
			hp = MAX_HP
			_refresh()

	move_and_slide()
	_attack_step(delta)
	sync_position = global_position
	sync_hp = hp
	_state_left -= delta
	if _state_left <= 0.0 and multiplayer.has_multiplayer_peer():
		_state_left = SyncRules.STATE_INTERVAL
		push_state.rpc(global_position, hp, attack_phase)


# M-7: the pattern, on the server. Nothing while held, dead-still or switched
# off; otherwise the timer runs, the windup is shown, the strike is booked
# with the judge at the start of the windup (so it can be caught), and the
# recovery follows the impact.
func _attack_step(delta: float) -> void:
	if not Tuning.server.dummy_attack_enabled or holder_peer != 0 or ServerAuthority.instance == null:
		if attack_phase != "":
			_set_attack_phase("")
		return
	var def := Skills.get_def("dummy_slam")
	if def == null:
		return
	match attack_phase:
		"":
			_attack_timer += delta
			if _attack_timer >= Tuning.server.dummy_attack_period:
				_attack_timer = 0.0
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
				_set_attack_phase("")


# M-7: caught mid-swing. The pattern stands still for `seconds`; the booked
# strike is the judge's to cancel.
func apply_catch_stun(seconds: float) -> void:
	_phase_left = seconds
	_set_attack_phase("stunned")


func _set_attack_phase(phase: String) -> void:
	attack_phase = phase
	_refresh()


# Which way the strike goes: the way the scarecrow faces.
func attack_direction() -> Vector3:
	var forward := -global_transform.basis.z
	forward.y = 0.0
	return forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD


@rpc("authority", "call_remote", "unreliable_ordered")
func push_state(at_position: Vector3, at_hp: float, at_phase := "") -> void:
	sync_position = at_position
	sync_hp = at_hp
	if at_phase != attack_phase:
		_set_attack_phase(at_phase)
	if not _has_state:
		# The first packet places it rather than easing in from the start mark.
		global_position = at_position
		_has_state = true


# A scarecrow is server-owned, so the body it is being carried by is looked up
# the same way the rock looks it up.
# Re-asserted every step rather than set once: on a client the hold row can
# arrive before the holder's body has spawned.
func _except_holder() -> void:
	var holder: Node3D = _peer_player(holder_peer) if holder_peer != 0 else null
	if holder == _excepted:
		return
	if is_instance_valid(_excepted):
		remove_collision_exception_with(_excepted)
	_excepted = null
	if holder != null:
		add_collision_exception_with(holder)
		_excepted = holder


func _peer_player(peer_id: int) -> Player:
	if Net.spawn_root == null:
		return null
	return Net.spawn_root.get_node_or_null(str(peer_id)) as Player


func _refresh() -> void:
	if _label != null:
		_label.text = "%d / %d" % [roundi(hp), roundi(MAX_HP)]
		if attack_phase == "windup":
			_label.text += "\n!"
	if _material != null:
		var colour := Color("c9b48a").lerp(Color("ff7b6b"), 1.0 - hp / MAX_HP)
		match attack_phase:
			"windup":
				colour = Color("ff4d3d")
			"recovery":
				colour = colour.darkened(0.35)
			"stunned":
				colour = Color("6fa8dc")
		_material.albedo_color = colour
