class_name Rock
extends RigidBody3D

# Something to pick up and throw. Owned by the host, as the design doc's
# authority table requires for anything that is not a player's own body.
#
# Clients never simulate a rock. They freeze it and follow the position the host
# sends: two solvers stepping the same rigid body from slightly different
# contact states disagree every frame, which reads as a rock that shakes.

const GROUP := "rock"
const LAYER := 16

# Below this it is a rock rolling into your shins, not a rock hitting you.
const HIT_SPEED := 3.0
const HIT_COOLDOWN := 0.5
const HIT_POWER_PER_SPEED := 0.6
const HIT_DAMAGE := 4.0
# A thrown rock leaves the thrower's own body alone for a moment: it starts
# above their head and would otherwise clip them on the way out.
const THROWER_GRACE := 0.3
# How long a new hold is left alone before the holder is required to be in the
# GRABBING state. A client's grab is approved here and the state that proves it
# only comes back a round trip later: without this the host granted the hold and
# dropped it on the very next frame, so a client could never carry a rock.
const HOLD_GRACE := 0.6
const STATE_INTERVAL := 0.05

var weight := 10.0
var home := Vector3.ZERO
# 0 means nobody. The host is the only one that writes it.
var holder_peer := 0

var _hit_times := {}
var _thrower_peer := 0
var _thrower_grace := 0.0
var _hold_grace := 0.0
var _state_left := 0.0
var _sync_position := Vector3.ZERO
var _sync_rotation := Vector3.ZERO
var _has_state := false
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
	collision_mask = Playground.WORLD_LAYER | Playground.WALL_LAYER | Playground.CLIMBABLE_LAYER \
		| Player.PLAYER_LAYER | Dummy.LAYER
	add_to_group(GROUP)
	home = global_position
	# A sphere on a flat plane rolls for ever without these, and a thrown rock
	# then wanders off the plaza minutes after it landed.
	# Angular damping and a rough surface are what stop a roll; linear damping
	# would also shorten the flight, which is the thing being measured.
	angular_damp = 2.0
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


static func radius_for(rock_weight: float) -> float:
	return 0.3 + rock_weight * 0.012


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		if _has_state:
			# Shown, not simulated.
			global_position = global_position.lerp(_sync_position, 1.0 - exp(-18.0 * delta))
			rotation = rotation.lerp(_sync_rotation, 1.0 - exp(-18.0 * delta))
		return

	if global_position.y < Tuning.values.kill_plane_y:
		# Fallen out of the world. There are only three rocks, so losing one is
		# losing a third of the stage: it comes back to its mark instead.
		holder_peer = 0
		freeze = false
		global_position = home
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		print("PLAYGROUND_ROCK_RETURNED rock=%s" % name)
		return

	_thrower_grace = maxf(0.0, _thrower_grace - delta)
	_hold_grace = maxf(0.0, _hold_grace - delta)
	if _thrower_grace == 0.0:
		_thrower_peer = 0
	if holder_peer != 0:
		var holder := _peer_player(holder_peer)
		if holder == null or (_hold_grace == 0.0 and holder.state != Player.State.GRABBING):
			# The hands that were holding it are gone, stunned or falling.
			host_release(holder_peer)
		else:
			global_position = holder.hand_position()
			linear_velocity = Vector3.ZERO
			angular_velocity = Vector3.ZERO

	_state_left -= delta
	if _state_left <= 0.0 and multiplayer.has_multiplayer_peer():
		_state_left = STATE_INTERVAL
		# The holder travels with the state: a client cannot tell whether its own
		# grab is still good without it, and would let go of a rock it is
		# holding the moment its own grace ran out.
		push_state.rpc(global_position, rotation, holder_peer)


@rpc("authority", "call_remote", "unreliable_ordered")
func push_state(at_position: Vector3, at_rotation: Vector3, held_by: int) -> void:
	_sync_position = at_position
	_sync_rotation = at_rotation
	holder_peer = held_by
	if not _has_state:
		# First packet lands the rock rather than easing it in from wherever the
		# scene put it.
		global_position = at_position
		rotation = at_rotation
	_has_state = true


# Decided on the host. Two players reaching at once means the first request to
# arrive is the one that gets it.
func host_grab(by_peer: int) -> bool:
	if not is_multiplayer_authority() or holder_peer != 0:
		return false
	var holder := _peer_player(by_peer)
	if holder == null:
		return false
	holder_peer = by_peer
	_hold_grace = HOLD_GRACE
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	global_position = holder.hand_position()
	print("PLAYGROUND_ROCK_GRAB rock=%s by=%d" % [name, by_peer])
	return true


func host_throw(by_peer: int, direction: Vector3, strength: float) -> void:
	if not is_multiplayer_authority() or holder_peer != by_peer:
		return
	holder_peer = 0
	freeze = false
	# Heavier rock, shorter throw: the same strength to weight rule the jump
	# and the shove use.
	var power: float = Tuning.values.throw_power * Tuning.ratio_mult(
		strength / maxf(weight, 0.1), Tuning.values.ratio_k_jump)
	linear_velocity = direction.normalized() * power
	angular_velocity = Vector3(randf_range(-4.0, 4.0), 0.0, randf_range(-4.0, 4.0))
	_thrower_peer = by_peer
	_thrower_grace = THROWER_GRACE
	_hit_times.clear()
	print("PLAYGROUND_ROCK_THROW rock=%s weight=%.0f power=%.2f" % [name, weight, power])


func host_release(by_peer: int) -> void:
	if not is_multiplayer_authority() or holder_peer != by_peer:
		return
	holder_peer = 0
	freeze = false
	linear_velocity = Vector3.ZERO
	print("PLAYGROUND_ROCK_DROP rock=%s by=%d" % [name, by_peer])


@rpc("any_peer", "call_remote", "reliable")
func request_grab() -> void:
	if not is_multiplayer_authority():
		return
	var by_peer := multiplayer.get_remote_sender_id()
	answer_grab.rpc_id(by_peer, host_grab(by_peer))


@rpc("authority", "call_remote", "reliable")
func answer_grab(approved: bool) -> void:
	var local := _peer_player(multiplayer.get_unique_id())
	if local != null and local.grab != null:
		local.grab.on_rock_answer(self, approved)


@rpc("any_peer", "call_remote", "reliable")
func request_throw(direction: Vector3, strength: float) -> void:
	host_throw(multiplayer.get_remote_sender_id(), direction, strength)


@rpc("any_peer", "call_remote", "reliable")
func request_release() -> void:
	host_release(multiplayer.get_remote_sender_id())


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
	ForceSystem.send(body, ForceSystem.make_event(
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
