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

const WORLD_LAYER := 1
const WALL_LAYER := 2
const CLIMBABLE_LAYER := 4
const PLAYER_LAYER := 8
const THROWABLE_LAYER := 16

const BODY_RADIUS := 0.4
const BODY_HALF_HEIGHT := 0.9

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
# The stats travel too: a shove is worked out from the pusher's strength
# against the target's weight, so every peer needs the target's numbers.
var sync_strength := 10.0
var sync_race_weight := 10.0
var sync_gear_weight := 0.0
var sync_weapon: int = WeaponKinds.Kind.NONE

var movement: PlayerMovement
var climb: PlayerClimb
var stamina := 100.0
var camera: QuarterCamera

var _visual: Node3D
var _material: StandardMaterial3D
var _label: Label3D
var _default_snap := 0.3
var spawn_point := Vector3.ZERO
var _respawn_left := 0.0
var _stun_left := 0.0
var weapon: int = WeaponKinds.Kind.NONE
var _weapon_node: Node3D


func _enter_tree() -> void:
	# The node is named after the peer, so every peer works out the authority
	# for itself with no extra message.
	# Recursive by default, which is the point: the MultiplayerSynchronizer is
	# already in the scene as a child, and a synchronizer created in code during
	# spawn processing never gets a network id at all.
	set_multiplayer_authority(name.to_int())


func _ready() -> void:
	stats = (load("res://data/default_stats.tres") as CharacterStats).duplicate(true)
	hp = stats.max_hp
	stamina = Tuning.values.stamina_max
	collision_layer = PLAYER_LAYER
	collision_mask = WORLD_LAYER | WALL_LAYER | CLIMBABLE_LAYER | PLAYER_LAYER
	floor_snap_length = _default_snap
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

		var panel := DebugPanel.new()
		panel.name = "DebugPanel"
		get_tree().current_scene.add_child(panel)
		panel.setup(self)
	set_physics_process(true)


func is_local() -> bool:
	return is_multiplayer_authority()


func change_state(new_state: int) -> void:
	if state == new_state:
		return
	state = new_state
	_apply_state_colour()
	state_changed.emit(new_state)


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
		_check_death(delta)
		if state == State.STUNNED:
			_stun_left -= delta
			if _stun_left <= 0.0:
				change_state(State.IDLE)
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
	# Remote bodies are shown, not simulated: a short lerp hides the gap
	# between state packets without letting them drift.
	global_position = global_position.lerp(sync_position, 1.0 - exp(-18.0 * delta))
	rotation.y = lerp_angle(rotation.y, sync_yaw, 1.0 - exp(-20.0 * delta))
	if sync_state != state:
		change_state(sync_state)


# Falling out of the world is not a special case anywhere else: the body dies
# and comes back, and everything that was in progress is dropped.
func _check_death(delta: float) -> void:
	if state == State.DEAD:
		_respawn_left -= delta
		if _respawn_left <= 0.0:
			respawn()
		return
	if global_position.y < Tuning.values.kill_plane_y:
		die()


func die() -> void:
	if not is_local() or state == State.DEAD:
		return
	velocity = Vector3.ZERO
	_respawn_left = Tuning.values.respawn_delay
	if movement != null:
		movement.cancel_target()
	change_state(State.DEAD)
	print("PLAYGROUND_DIED peer=%s y=%.1f" % [name, global_position.y])


# Also the R key: a restart is the same thing as coming back from a fall, so
# there is one path rather than two that can drift apart.
func respawn() -> void:
	if not is_local():
		return
	global_position = spawn_point
	velocity = Vector3.ZERO
	hp = stats.max_hp
	stamina = Tuning.values.stamina_max
	floor_snap_length = _default_snap
	_respawn_left = 0.0
	if movement != null:
		movement.cancel_target()
	change_state(State.IDLE)
	print("PLAYGROUND_RESPAWN peer=%s at=%s" % [name, spawn_point])


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
	if not is_local():
		return
	var direction: Vector3 = event.get("direction", Vector3.ZERO)
	var change := direction * ForceSystem.power_for(event, stats.total_weight())
	var ally := bool(event.get("is_ally_source", false))
	var damage := float(event.get("damage", 0.0))
	if climb != null and climb.is_climbing():
		# Knocked off the wall rather than pushed along it.
		climb.detach(0.0)
	if state == State.AIRBORNE:
		# Already flying: the push bends the arc and costs nothing, which is
		# what makes throwing a team mate a thing you can help with.
		velocity += change
		if not ally:
			_take_damage(damage)
	else:
		velocity = change
		if change.y > ForceSystem.UPWARD_LAUNCH:
			change_state(State.AIRBORNE)
		if not ally or Tuning.values.ally_ground_damage:
			_take_damage(damage)
		var stun := float(event.get("stun_time", 0.0))
		if stun > 0.0 and (not ally or Tuning.values.ally_ground_stun):
			_apply_stun(stun)
	print("PLAYGROUND_FORCE peer=%s power=%.2f airborne=%s hp=%.0f" % [
		name, change.length(), state == State.AIRBORNE, hp])


func _take_damage(amount: float) -> void:
	if amount <= 0.0:
		return
	hp = maxf(0.0, hp - amount)
	if hp <= 0.0:
		die()


func _apply_stun(seconds: float) -> void:
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


func _apply_state_colour() -> void:
	if _material != null:
		_material.albedo_color = Color(STATE_COLORS.get(state, "6fa8dc"))
	if _label != null:
		_label.text = "%s · %s" % [name, State.keys()[state]]
