class_name TimeBoundary
extends Node3D

# Legacy class/name retained for existing map and geometry checks.
# This is now ordinary terrain: a low slab and a climbable 3 m ledge.
# Debug boundaries are independently generated from data/world_boundaries.tres.

# The seam line on the ground: its midpoint, with the face standing at this z.
const SEAM := Vector3(-30.0, 0.0, 2.0)
const WIDTH := 20.0
const TOP_Y := 3.0
# Grass reaches from the seam back to the plaza's west edge, so the two are one
# continuous walking surface at y = 0.
const GRASS_DEPTH := 16.0
const SAND_DEPTH := 12.0
# Matched to the 0.6 m the rest of the map's climbable walls use: the mantle
# probe reaches 0.8 m past the face and has to come out over solid ground.
const FACE_THICKNESS := 0.6
# The face stands this far proud of the sand block it is sunk into, so the two
# front surfaces cannot z-fight and no crack shows along the cut.
const FACE_PROUD := 0.02

var face: StaticBody3D


func face_z() -> float:
	return SEAM.z + FACE_PROUD


# Collision goes under the navigation region so it is part of the bake; the
# decorations are ours and stay out of it.
func build(region: NavigationRegion3D) -> void:
	var grass_material := StandardMaterial3D.new()
	grass_material.albedo_color = Color("777d84")
	grass_material.roughness = 0.95
	_slab(
		region,
		"TimeGrass",
		Vector3(SEAM.x, -0.5, SEAM.z + GRASS_DEPTH * 0.5),
		Vector3(WIDTH, 1.0, GRASS_DEPTH),
		grass_material)

	var sand_material := StandardMaterial3D.new()
	sand_material.albedo_color = Color("858b91")
	sand_material.roughness = 0.9
	# Four metres deep rather than three: the bottom metre is never stood on,
	# it only stops the block looking like a floating slice from a low angle.
	_slab(
		region,
		"TimeSand",
		Vector3(SEAM.x, TOP_Y - 2.0, SEAM.z - SAND_DEPTH * 0.5),
		Vector3(WIDTH, 4.0, SAND_DEPTH),
		sand_material)

	face = _slab(
		region,
		"TimeCutFace",
		Vector3(SEAM.x, TOP_Y * 0.5, SEAM.z + FACE_PROUD * 0.5 - FACE_THICKNESS * 0.5),
		Vector3(WIDTH, TOP_Y, FACE_THICKNESS + FACE_PROUD),
		null)
	face.collision_layer = Playground.CLIMBABLE_LAYER
	var wall_material := ShaderMaterial.new()
	wall_material.shader = preload("res://shaders/dither_fade.gdshader")
	wall_material.set_shader_parameter("albedo", Color("6f9a63"))
	(face.get_node("Mesh") as MeshInstance3D).material_override = wall_material
	# Same contract as every other wall: the fader reads near_z and writes fade.
	# Standing on the sand fades the face out of the way; standing on the grass
	# leaves it solid, which is also when it has to be clickable to climb.
	face.set_meta("near_z", face_z())
	face.add_to_group(OcclusionFader.WALL_GROUP)


func _slab(
		region: NavigationRegion3D,
		slab_name: String,
		at_position: Vector3,
		size: Vector3,
		material: Material) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = slab_name
	body.position = at_position
	body.collision_layer = Playground.WORLD_LAYER
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	mesh_instance.material_override = material
	body.add_child(mesh_instance)
	region.add_child(body)
	return body


# Static geometry identity, independent of local debug visibility.
func signature() -> String:
	return "seam=%s width=%.1f top=%.2f face_z=%.3f layer=%d" % [
		SEAM, WIDTH, TOP_Y, face_z(), face.collision_layer if face != null else -1]
