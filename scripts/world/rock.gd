class_name Rock
extends RigidBody3D

# Something to pick up and throw. Owned by the host, as the design doc's
# authority table requires for anything that is not a player's own body.
#
# Clients never simulate a rock. They freeze it and follow the position the host
# sends: two solvers stepping the same rigid body from slightly different
# contact states disagree every frame, which reads as a rock that shakes.

const GROUP := "rock"
const LAYER := Layers.THROWABLE

# Below this it is a rock rolling into your shins, not a rock hitting you.
const HIT_SPEED := 3.0
const HIT_COOLDOWN := 0.5
const HIT_POWER_PER_SPEED := 0.6
const HIT_DAMAGE := 4.0
# A thrown rock leaves the thrower's own body alone for a moment: it starts
# above their head and would otherwise clip them on the way out.
const THROWER_GRACE := 0.3
const STATE_INTERVAL := 0.05
# CLAUDE.md lesson 4, with a rock instead of a capsule: a position that is
# assigned sweeps the body along the whole path, and whatever is standing in it
# is thrown out at teleport speed. A carried rock is assigned a new position
# every step, so both of these exist:
#  - its holder is excepted from colliding with it, because a rock picked up
#    from under its own holder's feet swept the holder up to hand height, which
#    raised the hand, which swept it up again: endless, about 200 m/s.
#  - any other long move blinds the rock for a moment, so a carried rock cannot
#    launch a bystander it is dragged through.
const TELEPORT_STEP := 2.0
const TELEPORT_BLIND := 0.2

var weight := 10.0
var home := Vector3.ZERO
# B-c: a read-only copy of a row in ServerAuthority's hold table. 0 means
# nobody. Only set_hold_display() writes it, on every peer alike, and nothing
# in here decides it.
var holder_peer := 0

var _hit_times := {}
var _thrower_peer := 0
var _thrower_grace := 0.0
var _state_left := 0.0
var _sync_position := Vector3.ZERO
var _sync_rotation := Vector3.ZERO
var _has_state := false
var _snap_state := false
var _blind_left := 0.0
var _excepted: Node3D
var _label: Label3D


func setup(rock_name: String, at_position: Vector3, rock_weight: float) -> void:
	name = rock_name
	position = at_position
	weight = rock_weight


func _enter_tree() -> void:
	set_multiplayer_authority(1)


func _ready() -> void:
	mass = weight
	collision_layer = LAYER
	# Rocks were left out of their own mask, so one thrown at another went
	# through it.
	collision_mask = Layers.SOLID_ROCK
	add_to_group(GROUP)
	add_to_group(ServerAuthority.HOLDABLE_GROUP)
	home = global_position
	# A sphere on a flat plane rolls for ever without these, and a thrown rock
	# then wanders off the plaza minutes after it landed.
	# Angular damping and a rough surface are what stop a roll; linear damping
	# would also shorten the flight, which is the thing being measured.
	angular_damp = 2.0
	_apply_gravity()
	Tuning.tuning_changed.connect(_apply_gravity)
	var surface := PhysicsMaterial.new()
	surface.friction = 1.0
	surface.rough = true
	physics_material_override = surface
	contact_monitor = true
	max_contacts_reported = 8
	body_entered.connect(_on_body_entered)
	_sync_position = global_position

	var radius := radius_for(weight)
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = radius
	collision.shape = shape
	add_child(collision)

	var mesh_instance := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	mesh_instance.mesh = sphere
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("8b8f94").lerp(Color("4a4f55"), clampf(weight / 20.0, 0.0, 1.0))
	material.roughness = 0.9
	mesh_instance.material_override = material
	add_child(mesh_instance)

	_label = Label3D.new()
	_label.text = "%.0fkg" % weight
	_label.position = Vector3(0.0, radius + 0.35, 0.0)
	_label.font_size = 24
	_label.outline_size = 6
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	add_child(_label)

	if not is_multiplayer_authority():
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		freeze = true
	set_physics_process(true)


# A rigid body falls under the project's gravity, which is Godot's 9.8, while
# every character in this game falls under PhysicsTuning.gravity. Nobody chose
# that: it meant a thrown rock hung in the air more than twice as long as a
# thrown person and flew 22 m, and the debug panel's gravity slider moved people
# without moving rocks. The work order has one gravity, so this scales the
# body's to match it and follows the slider.
func _apply_gravity() -> void:
	var project_gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	if project_gravity <= 0.0:
		return
	gravity_scale = Tuning.values.gravity / project_gravity


static func radius_for(rock_weight: float) -> float:
	return 0.3 + rock_weight * 0.012


func _physics_process(delta: float) -> void:
	_tick_blind(delta)
	if not is_multiplayer_authority():
		_except_holder()
		if _has_state:
			# Shown, not simulated.
			if _snap_state or global_position.distance_to(_sync_position) > TELEPORT_STEP:
				if not _snap_state:
					_blind_for_teleport()
				global_position = _sync_position
				rotation = _sync_rotation
				_snap_state = false
			else:
				global_position = global_position.lerp(_sync_position, 1.0 - exp(-18.0 * delta))
				rotation = rotation.lerp(_sync_rotation, 1.0 - exp(-18.0 * delta))
		return

	if global_position.y < Tuning.values.kill_plane_y:
		# Fallen out of the world. There are only three rocks, so losing one is
		# losing a third of the stage: it comes back to its mark instead.
		freeze = false
		global_position = home
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		print("PLAYGROUND_ROCK_RETURNED rock=%s" % name)
		return

	_thrower_grace = maxf(0.0, _thrower_grace - delta)
	if _thrower_grace == 0.0:
		_thrower_peer = 0
	if holder_peer != 0:
		# Whether the hold still stands is the table's ruling, made once for
		# every kind of held body; here the rock only rides the hand.
		_except_holder()
		var holder := _peer_player(holder_peer)
		if holder != null:
			var hand := holder.hand_position()
			if global_position.distance_to(hand) > TELEPORT_STEP:
				_blind_for_teleport()
			global_position = hand
			linear_velocity = Vector3.ZERO
			angular_velocity = Vector3.ZERO

	_state_left -= delta
	if _state_left <= 0.0 and multiplayer.has_multiplayer_peer():
		_state_left = STATE_INTERVAL
		# Position only. The holder used to ride along here as well, which meant
		# two sources for one fact; it now comes from the hold table alone.
		push_state.rpc(global_position, rotation)


@rpc("authority", "call_remote", "unreliable_ordered")
func push_state(at_position: Vector3, at_rotation: Vector3) -> void:
	_sync_position = at_position
	_sync_rotation = at_rotation
	if not _has_state:
		_snap_state = true
	_has_state = true


# Written by ServerAuthority's hold table and by nothing else. On the server
# this is also where a hold starts and stops mattering physically, because the
# table applies the row the moment it changes.
func set_hold_display(peer: int) -> void:
	if holder_peer == peer:
		return
	holder_peer = peer
	# Set on every peer, because every peer assigns this rock's position: the
	# host from the hand, a client from the state packets.
	_except_holder()
	if not is_multiplayer_authority():
		return
	if peer != 0:
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		freeze = true
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
	else:
		freeze = false


# A body cannot be pushed by what it is carrying. Re-asserted rather than set
# once: on a client the row can arrive before the holder's body has spawned.
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


# Collision off for a moment after a long jump, so the sweep cannot carry
# anyone with it.
func _blind_for_teleport() -> void:
	_blind_left = TELEPORT_BLIND
	collision_layer = 0


func _tick_blind(delta: float) -> void:
	if _blind_left <= 0.0:
		return
	_blind_left -= delta
	if _blind_left <= 0.0:
		collision_layer = LAYER


# Stage E: a thrown rock is given its speed by the one force door, like every
# other push in the game. server_throw() used to work the velocity out in here,
# which meant the throw was the one force that did not go through the door.
func apply_force_event(event: Dictionary) -> void:
	if not is_multiplayer_authority():
		return
	var direction: Vector3 = event.get("direction", Vector3.ZERO)
	if not direction.is_finite():
		return
	freeze = false
	var change := ForceSystem.change_for(event, weight, 1.0, false)
	linear_velocity = change
	angular_velocity = Vector3(randf_range(-4.0, 4.0), 0.0, randf_range(-4.0, 4.0))
	_hit_times.clear()
	print("PLAYGROUND_ROCK_THROW rock=%s weight=%.0f speed=%.2f" % [
		name, weight, change.length()])


# Who let go, for the grace that stops a thrown rock clipping the thrower on
# the way out. Told by the judge, because the row that knew it is erased by the
# time the force goes out.
func note_thrown(thrower_peer: int) -> void:
	_thrower_peer = thrower_peer
	_thrower_grace = THROWER_GRACE


# Judged on the host, as the work order says, and routed through the single
# force entry point like every other push in the game.
func _on_body_entered(body: Node) -> void:
	if not is_multiplayer_authority() or holder_peer != 0:
		return
	if not body.has_method("apply_force_event"):
		return
	var speed := linear_velocity.length()
	if speed < HIT_SPEED:
		return
	if body is Player and (body as Player).get_multiplayer_authority() == _thrower_peer and _thrower_grace > 0.0:
		return
	var key := body.get_path()
	var now := float(Time.get_ticks_msec()) / 1000.0
	if now - float(_hit_times.get(key, -10.0)) < HIT_COOLDOWN:
		return
	_hit_times[key] = now
	var direction := linear_velocity.normalized()
	direction.y = maxf(direction.y, 0.15)
	# No one's strength behind it once it has left the hand: a rock in flight is
	# an environmental force, so source_strength is 0.
	# Through the judge, not straight at the force system: B-d made the damage
	# a ruling, and send_force() is where it is made. Sent directly, a rock hit
	# knocked a person about and cost them nothing.
	ServerAuthority.instance.send_force(body, ForceSystem.make_event(
		ForceSystem.Kind.KNOCKBACK,
		direction,
		speed * HIT_POWER_PER_SPEED,
		0.0,
		1,
		false,
		HIT_DAMAGE,
		0.0))
	print("PLAYGROUND_ROCK_HIT rock=%s target=%s speed=%.2f" % [name, body.name, speed])


func _peer_player(peer_id: int) -> Player:
	if Net.spawn_root == null:
		return null
	return Net.spawn_root.get_node_or_null(str(peer_id)) as Player
