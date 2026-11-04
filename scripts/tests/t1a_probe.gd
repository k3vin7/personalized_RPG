extends SceneTree

# T-1a: does the Terrain3D GDExtension load in a headless run? Run with
#   godot --headless --path . --script scripts/tests/t1a_probe.gd
# Prints the classes, the version string, the collision modes, and whether
# an empty terrain answers a height query (NAN outside any region).

func _init() -> void:
	var classes := ["Terrain3D", "Terrain3DData", "Terrain3DRegion", "Terrain3DMaterial",
		"Terrain3DAssets", "Terrain3DCollision", "Terrain3DInstancer", "Terrain3DMesher"]
	for name_text in classes:
		print("T1A_PROBE class=%s exists=%s" % [name_text, ClassDB.class_exists(name_text)])
	if not ClassDB.class_exists("Terrain3D"):
		print("T1A_PROBE_RESULT loaded=false")
		quit(1)
		return
	var terrain: Node = ClassDB.instantiate("Terrain3D")
	print("T1A_PROBE version=%s" % terrain.get_version())
	print("T1A_PROBE is_node3d=%s" % (terrain is Node3D))
	root.add_child(terrain)
	var data: Object = terrain.get("data")
	print("T1A_PROBE data=%s" % (data != null))
	if data != null:
		var h: float = data.get_height(Vector3(1.0, 0.0, 1.0))
		print("T1A_PROBE empty_height_is_nan=%s (%s)" % [is_nan(h), h])
	var collision: Object = terrain.get("collision")
	print("T1A_PROBE collision_object=%s" % (collision != null))
	if collision != null:
		print("T1A_PROBE collision_mode=%s" % collision.get("mode"))
		for prop in collision.get_property_list():
			var pname := String(prop["name"])
			if pname.begins_with("_") or pname in ["script", "RefCounted", "Terrain3DCollision", "Object"]:
				continue
			print("T1A_PROBE collision_prop %s = %s" % [pname, collision.get(pname)])
	# Enum values on the collision class, if exposed.
	for constant in ClassDB.class_get_integer_constant_list("Terrain3DCollision", true):
		print("T1A_PROBE collision_const %s = %d" % [constant, ClassDB.class_get_integer_constant("Terrain3DCollision", constant)])
	print("T1A_PROBE_RESULT loaded=true")
	terrain.queue_free()
	quit(0)
