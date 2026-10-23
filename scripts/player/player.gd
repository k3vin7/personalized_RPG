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

var movement: PlayerMovement
var camera: QuarterCamera

var _visual: Node3D
var _material: StandardMaterial3D
var _label: Label3D


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
	collision_layer = PLAYER_LAYER
	collision_mask = WORLD_LAYER | WALL_LAYER | CLIMBABLE_LAYER | PLAYER_LAYER
	_build_body()
	sync_position = global_position

	if is_local():
		movement = PlayerMovement.new()
		movement.name = "PlayerMovement"
		add_child(movement)
		movement.setup(self)

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
	set_physics_process(true)


func is_local() -> bool:
	return is_multiplayer_authority()


func change_state(new_state: int) -> void:
	if state == new_state:
		return
	state = new_state
	_apply_state_colour()
	state_changed.emit(new_state)


func is_grounded_state() -> bool:
	return state == State.IDLE or state == State.MOVE


func _physics_process(delta: float) -> void:
	if is_local():
		sync_position = global_position
		sync_yaw = rotation.y
		sync_state = state
		return
	# Remote bodies are shown, not simulated: a short lerp hides the gap
	# between state packets without letting them drift.
	global_position = global_position.lerp(sync_position, 1.0 - exp(-18.0 * delta))
	rotation.y = lerp_angle(rotation.y, sync_yaw, 1.0 - exp(-20.0 * delta))
	if sync_state != state:
		change_state(sync_state)


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
