class_name WolfCorpse
extends Rock

# 늑대 a: what a dead wolf leaves. A rock in every rule -- the same layer, the
# same hold table, the same lift limit off its weight, the same throw and hit
# door -- with its own picture and its own size (a wolf, not the ball a 40 kg
# rock would be). Built by the wolf on every peer when it dies and removed by
# it after Tuning.server.wolf_corpse_time (Wolf.show_corpse / hide_corpse).

const COLOUR := Color("5d6064")


func _ready() -> void:
	super()
	if _label != null:
		_label.text = "늑대 시체 %.0fkg" % weight


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
