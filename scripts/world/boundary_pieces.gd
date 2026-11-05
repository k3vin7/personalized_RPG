class_name BoundaryPieces
extends Node3D

# T-1c: the three ways a map piece's boundary shows itself, as blockout
# meshes on the terrain test region. The world rule: a boundary can be a
# step or a cliff, a rock cut clean through, or water that is suddenly
# there -- "joined a little oddly", no effect, and not cliffs every time.
#
#   1. The cut mountain section: a 6 m step whose south face is the cut.
#      West half climbable rock (CLIMBABLE layer, the climb colour), east
#      half slippery (WALL layer, the smooth-wall colour). One tag tells
#      them apart: meta "boundary" = "cliff_climb" / "cliff_slip".
#   2. The cut rock: a boulder sliced on the region seam (x = 192); the cut
#      is a flat vertical face. Rock, so climbable.
#   3. The sudden water: a flat pool at the east edge. There is no swim rule
#      yet, so it blocks: an invisible WALL-layer box stands in it. Tagged
#      "water" for the rule that comes later.
#
# Authored as CSG (what the blockout pipeline in T-1e will hand over), then
# baked: the CSG's own mesh (get_meshes()) becomes a trimesh collision on a
# StaticBody3D, which the physics, the navigation parser and the climb code
# all read; the CSG node stays as the picture. A CSG builds its mesh on a
# deferred call after it enters the tree, so the bake is deferred behind it
# (and the playground defers its navigation bake behind this). If a mesh is
# still empty a plain box stands in, and the check reports which.

const CLIFF_WEST := Vector3(207.5, 3.0, 50.0)
const CLIFF_EAST := Vector3(222.5, 3.0, 50.0)
const CLIFF_HALF_SIZE := Vector3(15.0, 6.0, 20.0)
const CLIFF_FACE_Z := 40.0
const CLIFF_TOP_Y := 6.0
const ROCK_CENTRE := Vector3(192.0, 1.6, 50.0)
const ROCK_RADIUS := 3.0
const ROCK_CUT_X := 192.0
const WATER_CENTRE := Vector3(241.0, 0.0, 16.0)
const WATER_SIZE := Vector3(18.0, 0.4, 16.0)
const WATER_BLOCK_HEIGHT := 2.0
const CLIMB_COLOUR := Color("6f9a63")
const SLIP_COLOUR := Color("555b62")
const ROCK_COLOUR := Color("7a8a6a")
const WATER_COLOUR := Color(0.2, 0.45, 0.8, 0.55)
const GROUP := "boundary"

var bodies := {}
var bake_results := {}
var _pending: Array = []
var baked := false


static func build(parent: Node) -> BoundaryPieces:
	var pieces := BoundaryPieces.new()
	pieces.name = "BoundaryPieces"
	parent.add_child(pieces)
	pieces._build()
	return pieces


func _build() -> void:
	# 1. The cut mountain section, two halves.
	var west := CSGBox3D.new()
	west.name = "CliffClimbCSG"
	west.size = CLIFF_HALF_SIZE
	west.position = CLIFF_WEST
	west.material = _flat(CLIMB_COLOUR)
	add_child(west)
	_bake(west, "CliffClimb", Layers.CLIMBABLE, "cliff_climb")
	var east := CSGBox3D.new()
	east.name = "CliffSlipCSG"
	east.size = CLIFF_HALF_SIZE
	east.position = CLIFF_EAST
	east.material = _flat(SLIP_COLOUR)
	add_child(east)
	_bake(east, "CliffSlip", Layers.WALL, "cliff_slip")
	# 2. The cut rock: a sphere minus everything east of the seam.
	var rock := CSGCombiner3D.new()
	rock.name = "CutRockCSG"
	rock.position = ROCK_CENTRE
	var ball := CSGSphere3D.new()
	ball.radius = ROCK_RADIUS
	ball.radial_segments = 24
	ball.rings = 12
	ball.material = _flat(ROCK_COLOUR)
	rock.add_child(ball)
	var cut := CSGBox3D.new()
	cut.operation = CSGShape3D.OPERATION_SUBTRACTION
	cut.size = Vector3(ROCK_RADIUS * 2.0 + 1.0, ROCK_RADIUS * 2.0 + 1.0, ROCK_RADIUS * 2.0 + 1.0)
	cut.position = Vector3((ROCK_CUT_X - ROCK_CENTRE.x) + cut.size.x * 0.5, 0.0, 0.0)
	rock.add_child(cut)
	add_child(rock)
	_bake(rock, "CutRock", Layers.CLIMBABLE, "rock")
	# 3. The sudden water: the picture, and the block.
	var water := CSGBox3D.new()
	water.name = "WaterCSG"
	water.size = WATER_SIZE
	water.position = WATER_CENTRE + Vector3(0.0, -WATER_SIZE.y * 0.5 + 0.05, 0.0)
	var water_material := _flat(WATER_COLOUR)
	water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water.material = water_material
	water.use_collision = false
	add_child(water)
	var block := StaticBody3D.new()
	block.name = "WaterBlock"
	block.position = WATER_CENTRE + Vector3(0.0, WATER_BLOCK_HEIGHT * 0.5, 0.0)
	block.collision_layer = Layers.WALL
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(WATER_SIZE.x, WATER_BLOCK_HEIGHT, WATER_SIZE.z)
	shape.shape = box
	block.add_child(shape)
	block.set_meta("boundary", "water")
	block.add_to_group(GROUP)
	block.add_to_group("water")
	add_child(block)
	bodies["water"] = block
	bake_results["water"] = "box"
	call_deferred("_bake_all")


static func _flat(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.9
	return material


# Queued; the bodies are made in _bake_all once the CSG meshes exist.
func _bake(csg: CSGShape3D, body_name: String, layer: int, kind: String) -> void:
	csg.use_collision = false
	_pending.append({"csg": csg, "name": body_name, "layer": layer, "kind": kind})


func _bake_all() -> void:
	for entry: Dictionary in _pending:
		_bake_now(entry["csg"], entry["name"], entry["layer"], entry["kind"])
	_pending.clear()
	baked = true
	print("PLAYGROUND_BOUNDARY_PIECES %s" % [bake_results])


# The CSG's mesh as a trimesh collision on a StaticBody3D on `layer`; a box
# stand-in if the mesh is still empty.
func _bake_now(csg: CSGShape3D, body_name: String, layer: int, kind: String) -> void:
	var body := StaticBody3D.new()
	var how := "box"
	var meshes := csg.get_meshes()
	if meshes.size() >= 2 and meshes[1] is Mesh and (meshes[1] as Mesh).get_surface_count() > 0:
		var shape := CollisionShape3D.new()
		shape.name = "Trimesh"
		shape.shape = (meshes[1] as Mesh).create_trimesh_shape()
		shape.transform = meshes[0]
		body.add_child(shape)
		how = "trimesh"
	else:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var aabb := csg.get_aabb()
		box.size = aabb.size if aabb.size.length() > 0.01 else Vector3.ONE
		shape.shape = box
		shape.position = aabb.get_center()
		body.add_child(shape)
	body.name = body_name
	body.position = csg.position
	body.rotation = csg.rotation
	body.collision_layer = layer
	body.collision_mask = 0
	body.set_meta("boundary", kind)
	body.add_to_group(GROUP)
	add_child(body)
	bodies[kind] = body
	bake_results[kind] = how


func body_for(kind: String) -> StaticBody3D:
	return bodies.get(kind) as StaticBody3D
