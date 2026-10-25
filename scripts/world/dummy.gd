class_name Dummy
extends CharacterBody3D

# A thing to push. Owned by the host, as the design doc's table requires for
# anything that is not a player's own body, and it walks itself back to where it
# started so the next shove starts from the same place.

const LAYER := Layers.DUMMY
const RETURN_DELAY := 2.0
const RETURN_SPEED := 2.0
const MAX_HP := 60.0
# 20 state packets a second. A dummy built in code has no synchronizer of its
# own, so the host pushes its state: without this a client saw a dummy that
# never moved however hard it was shoved.
const STATE_INTERVAL := 0.05

var home := Vector3.ZERO
var hp := MAX_HP
var sync_position := Vector3.ZERO
var sync_hp := MAX_HP

var _settle_left := 0.0
var _state_left := 0.0
var _has_state := false
var _label: Label3D
var _material: StandardMaterial3D


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
	collision_layer = LAYER
	# Was terrain only, which is why a player walked straight through a
	# scarecrow and two scarecrows could stand in the same spot.
	collision_mask = Layers.SOLID_DUMMY

	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4
	shape.height = 1.8
	collision.shape = shape
	add_child(collision)

	var mesh_instance := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.8
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
	var direction: Vector3 = event.get("direction", Vector3.ZERO)
	velocity = direction * ForceSystem.power_for(event, Dummy.MAX_HP * 0.2)
	hp = maxf(0.0, hp - float(event.get("damage", 0.0)))
	_settle_left = RETURN_DELAY
	_refresh()
	print("PLAYGROUND_DUMMY_HIT name=%s hp=%.0f push=%.2f" % [name, hp, velocity.length()])


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		# Shown, not simulated.
		if not _has_state:
			return
		global_position = global_position.lerp(sync_position, 1.0 - exp(-18.0 * delta))
		if not is_equal_approx(hp, sync_hp):
			hp = sync_hp
			_refresh()
		return

	if not is_on_floor():
		velocity.y -= Tuning.values.gravity * delta
	else:
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
	sync_position = global_position
	sync_hp = hp
	_state_left -= delta
	if _state_left <= 0.0 and multiplayer.has_multiplayer_peer():
		_state_left = STATE_INTERVAL
		push_state.rpc(global_position, hp)


@rpc("authority", "call_remote", "unreliable_ordered")
func push_state(at_position: Vector3, at_hp: float) -> void:
	sync_position = at_position
	sync_hp = at_hp
	if not _has_state:
		# The first packet places it rather than easing in from the start mark.
		global_position = at_position
		_has_state = true


func _refresh() -> void:
	if _label != null:
		_label.text = "%d / %d" % [roundi(hp), roundi(MAX_HP)]
	if _material != null:
		_material.albedo_color = Color("c9b48a").lerp(Color("ff7b6b"), 1.0 - hp / MAX_HP)
