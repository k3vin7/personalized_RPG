class_name WolfCorpse
extends Rock

# 늑대 a: what a dead wolf leaves. A rock in every rule -- the same layer, the
# same hold table, the same lift limit off its weight, the same throw and hit
# door -- with its own picture and its own size (a wolf, not the ball a 40 kg
# rock would be). Built by the wolf on every peer when it dies and removed by
# it after Tuning.server.wolf_corpse_time (Wolf.show_corpse / hide_corpse).

const COLOUR := Color("5d6064")


# The state packets (Rock.push_state, unreliable) and the two messages that
# make and remove the node on a client (Wolf.show_corpse / hide_corpse,
# reliable) travel on different channels, so either can overtake the other.
# A packet for a node that is not there yet, or no longer there, is an engine
# error on the client ("Node not found"). So the first packet waits a moment
# for the node to exist everywhere, and a carcass that is gone leaves the
# game at once but stays in the tree, silent, until the last packet for it
# has landed.
const FIRST_STATE_DELAY := 0.25
const LINGER := 2.0

var _retired := false


func _ready() -> void:
	super()
	if _label != null:
		_label.text = "늑대 시체 %.0fkg" % weight
	if is_multiplayer_authority():
		_state_left = FIRST_STATE_DELAY


func is_retired() -> bool:
	return _retired


# Gone: not seen, not solid, not holdable, and (on the server) no longer
# sending. The node is freed LINGER later.
func retire() -> void:
	if _retired:
		return
	_retired = true
	if is_multiplayer_authority() and ServerAuthority.instance != null:
		ServerAuthority.instance.drop_hold_of(self, "target_gone")
	visible = false
	collision_layer = 0
	collision_mask = 0
	freeze = true
	remove_from_group(GROUP)
	remove_from_group(ServerAuthority.HOLDABLE_GROUP)
	set_physics_process(false)
	get_tree().create_timer(LINGER).timeout.connect(queue_free)


func body_radius() -> float:
	return Wolf.BODY_RADIUS


func _build_visual(_radius: float) -> void:
	var mesh_instance := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = Wolf.BODY_RADIUS
	capsule.height = Wolf.BODY_LENGTH
	mesh_instance.mesh = capsule
	mesh_instance.transform.basis = Basis(Vector3.RIGHT, PI * 0.5)
	var material := StandardMaterial3D.new()
	material.albedo_color = COLOUR
	material.roughness = 0.9
	mesh_instance.material_override = material
	add_child(mesh_instance)
