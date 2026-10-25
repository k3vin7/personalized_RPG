class_name TimeBoundary
extends Node3D

# Stage 8. Two pieces of ground from different times, cut vertically and pushed
# together: green grass at 0 m on the camera side, sand 3 m up behind it.
#
# The cut can only face the camera. The view never rotates and a face pointing
# away from it is never drawn, which is the same reason the climb ring leaves
# out its 90 and 270 degree walls. So the sand is the far side (smaller z), the
# grass is the near side, and the face's normal is +z.
#
# Everything here is built from the same table on every peer, decorations
# included, and the particles are given a fixed seed: nothing about the seam
# travels over the network, so nothing about it can differ between two screens.

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
const PANE_GAP := 0.04
const DUST_SEED := 80825

var face: StaticBody3D


func face_z() -> float:
	return SEAM.z + FACE_PROUD


# Collision goes under the navigation region so it is part of the bake; the
# decorations are ours and stay out of it.
func build(region: NavigationRegion3D) -> void:
	var grass_material := StandardMaterial3D.new()
	grass_material.albedo_color = Color("5c8b4a")
	grass_material.roughness = 0.95
	_slab(
		region,
		"TimeGrass",
		Vector3(SEAM.x, -0.5, SEAM.z + GRASS_DEPTH * 0.5),
		Vector3(WIDTH, 1.0, GRASS_DEPTH),
		grass_material)

	var sand_material := StandardMaterial3D.new()
	sand_material.albedo_color = Color("c2a977")
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
	var strata := ShaderMaterial.new()
	strata.shader = load("res://shaders/strata.gdshader")
	strata.set_shader_parameter("fade", 1.0)
	(face.get_node("Mesh") as MeshInstance3D).material_override = strata
	# Same contract as every other wall: the fader reads near_z and writes fade.
	# Standing on the sand fades the face out of the way; standing on the grass
	# leaves it solid, which is also when it has to be clickable to climb.
	face.set_meta("near_z", face_z())
	face.add_to_group(OcclusionFader.WALL_GROUP)

	_build_pane()
	_build_dust()


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


# A pane of refraction standing in front of the face. Unshaded and never
# written to the depth buffer, so it bends what is behind it without taking
# part in the sorting of anything else.
func _build_pane() -> void:
	var pane := MeshInstance3D.new()
	pane.name = "SeamPane"
	var quad := QuadMesh.new()
	# Barely over the lip: the glow belongs on the cut line, not above it.
	quad.size = Vector2(WIDTH, TOP_Y + 0.1)
	pane.mesh = quad
	pane.position = Vector3(SEAM.x, TOP_Y * 0.5, face_z() + PANE_GAP)
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/time_boundary.gdshader")
	pane.material_override = material
	# A screen reading pane that is culled by its own bounds flickers at the
	# edge of the view; the box it is given covers the whole seam instead.
	pane.custom_aabb = AABB(
		Vector3(-WIDTH * 0.5, -TOP_Y, -1.0), Vector3(WIDTH, TOP_Y * 2.0, 2.0))
	add_child(pane)


# Dust that hangs instead of falling: the air on the seam is as stopped as the
# ground is.
func _build_dust() -> void:
	var dust := GPUParticles3D.new()
	dust.name = "SeamDust"
	dust.position = Vector3(SEAM.x, TOP_Y * 0.6, SEAM.z + 0.9)
	dust.amount = 120
	dust.lifetime = 10.0
	dust.preprocess = 6.0
	dust.visibility_aabb = AABB(
		Vector3(-WIDTH * 0.5, -2.0, -2.0), Vector3(WIDTH, TOP_Y + 4.0, 4.0))
	# The same dust on both screens. Without this each process seeds itself
	# from its own clock and the two look alike but are not the same.
	dust.use_fixed_seed = true
	dust.seed = DUST_SEED

	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(WIDTH * 0.5, TOP_Y * 0.7, 1.1)
	process.direction = Vector3(0.0, 1.0, 0.0)
	process.spread = 180.0
	process.initial_velocity_min = 0.01
	process.initial_velocity_max = 0.07
	# Not weightless, just nearly: a mote drifts a few centimetres in its whole
	# life and never settles.
	process.gravity = Vector3(0.0, 0.015, 0.0)
	process.scale_min = 0.5
	process.scale_max = 1.4
	process.color = Color(1.0, 0.96, 0.84, 0.38)
	dust.process_material = process

	var mote := QuadMesh.new()
	mote.size = Vector2(0.05, 0.05)
	var mote_material := StandardMaterial3D.new()
	mote_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mote_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mote_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mote_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mote_material.vertex_color_use_as_albedo = true
	mote_material.albedo_color = Color(1.0, 0.97, 0.88, 1.0)
	mote_material.disable_receive_shadows = true
	mote.material = mote_material
	dust.draw_pass_1 = mote
	add_child(dust)


# Everything a second peer would have to agree on for the seam to look the
# same, in one line that can be compared between two logs.
func signature() -> String:
	var dust := get_node_or_null("SeamDust") as GPUParticles3D
	var pane := get_node_or_null("SeamPane") as MeshInstance3D
	return "seam=(%.2f, %.2f, %.2f) width=%.1f top=%.2f face_z=%.3f layer=%d pane=(%.2f, %.2f, %.2f) dust=%d/%d/%d" % [
		SEAM.x, SEAM.y, SEAM.z, WIDTH, TOP_Y, face_z(),
		face.collision_layer if face != null else -1,
		pane.position.x if pane != null else 0.0,
		pane.position.y if pane != null else 0.0,
		pane.position.z if pane != null else 0.0,
		dust.amount if dust != null else -1,
		dust.seed if dust != null else -1,
		int(dust.use_fixed_seed) if dust != null else -1]
