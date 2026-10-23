class_name WeaponKinds
extends RefCounted

# Which weapon the character is carrying. No combat here: the rack exists so a
# choice can be made, seen on both screens, and later fed to whatever uses it.

enum Kind {
	NONE,
	SWORD,
	BOW,
	SPEAR,
	SHIELD,
	STAFF,
}

const LABELS := {
	Kind.NONE: "맨손",
	Kind.SWORD: "검",
	Kind.BOW: "활",
	Kind.SPEAR: "창",
	Kind.SHIELD: "방패",
	Kind.STAFF: "스태프",
}

const COLORS := {
	Kind.NONE: "9aa3ad",
	Kind.SWORD: "dfe6ef",
	Kind.BOW: "c9a66b",
	Kind.SPEAR: "b8c4d0",
	Kind.SHIELD: "4a6fa5",
	Kind.STAFF: "8f6bc9",
}


# Primitive stand-ins, shaped enough to tell apart at quarter view distance.
static func build_mesh(kind: int) -> Node3D:
	var root := Node3D.new()
	var color := Color(COLORS.get(kind, "ffffff"))
	match kind:
		Kind.SWORD:
			root.add_child(_part(Vector3(0.07, 0.07, 1.1), Vector3(0.0, 0.0, -0.55), color))
			root.add_child(_part(Vector3(0.26, 0.06, 0.06), Vector3(0.0, 0.0, -0.02), Color("3b3027")))
		Kind.BOW:
			var arc := _part(Vector3(0.06, 1.3, 0.06), Vector3(0.0, 0.0, -0.1), color)
			arc.rotation_degrees.x = 12.0
			root.add_child(arc)
			root.add_child(_part(Vector3(0.02, 1.25, 0.02), Vector3(0.0, 0.0, 0.06), Color("efe8d8")))
		Kind.SPEAR:
			root.add_child(_part(Vector3(0.06, 0.06, 2.0), Vector3(0.0, 0.0, -0.9), Color("6b5236")))
			root.add_child(_part(Vector3(0.12, 0.12, 0.34), Vector3(0.0, 0.0, -2.0), color))
		Kind.SHIELD:
			root.add_child(_part(Vector3(0.7, 0.9, 0.08), Vector3(0.0, 0.0, -0.1), color))
		Kind.STAFF:
			root.add_child(_part(Vector3(0.07, 0.07, 1.7), Vector3(0.0, 0.0, -0.75), Color("6b5236")))
			var orb := MeshInstance3D.new()
			var sphere := SphereMesh.new()
			sphere.radius = 0.16
			sphere.height = 0.32
			orb.mesh = sphere
			orb.position = Vector3(0.0, 0.0, -1.65)
			var orb_material := StandardMaterial3D.new()
			orb_material.albedo_color = color
			orb_material.emission_enabled = true
			orb_material.emission = color
			orb_material.emission_energy_multiplier = 0.8
			orb.material_override = orb_material
			root.add_child(orb)
		_:
			pass
	return root


static func _part(size: Vector3, at_position: Vector3, color: Color) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	mesh_instance.position = at_position
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = 0.4
	material.roughness = 0.5
	mesh_instance.material_override = material
	return mesh_instance
